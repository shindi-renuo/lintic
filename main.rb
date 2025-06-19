# frozen_string_literal: true

require "dotenv"
require "octokit"
require "ruby/openai"
require "json"
require "tempfile"
require "stringio"
require "base64"
require "logger"
require "rubocop"

Dotenv.load

# Main class for automated linting fixes in GitHub PRs
class Lintic
  class LinticError < StandardError; end
  class GitHubError < LinticError; end
  class LintingError < LinticError; end
  class AIError < LinticError; end

  # Configuration and constants
  module Config
    DEFAULT_MODEL = "qwen2.5-coder:1.5b"
    DEFAULT_OLLAMA_URI = "http://localhost:11434/v1/"
    DEFAULT_AI_TOKEN = "ollama"
    REQUEST_TIMEOUT = 120
    AI_TEMPERATURE = 0.1
    MAX_SUMMARY_TOKENS = 1000
    MAX_FIX_TOKENS = 4000
    BRANCH_PREFIX = "lintic/fix-pr"
    COMMIT_MESSAGE = "🤖 Fix linting errors with Lintic"
    TEMPFILE_PREFIX = "lintic_check"
    RUBY_FILE_EXTENSIONS = %w[.rb .rake .gemspec].freeze
    RUBY_SHEBANG_PATTERN = /\A#!.*ruby/
  end

  def initialize
    @logger = LoggerSetup.create
    @github_client = GitHubClientSetup.create(@logger)
    @ai_client = AIClientSetup.create(@logger)
    @logger.info("Lintic initialized successfully")
  end

  def process_pr(pr_number, repo)
    InputValidator.validate(pr_number, repo)
    @logger.info("Processing PR ##{pr_number} in #{repo}")

    begin
      processor = PRProcessor.new(@github_client, @ai_client, @logger)
      processor.process(pr_number, repo)
    rescue StandardError => e
      @logger.error("Failed to process PR: #{e.message}")
      raise LinticError, "PR processing failed: #{e.message}"
    end
  end

  # Helper class for input validation
  class InputValidator
    def self.validate(pr_number, repo)
      validate_pr_number(pr_number)
      validate_repo(repo)
    end

    def self.validate_pr_number(pr_number)
      return if pr_number.is_a?(Integer) && pr_number.positive?

      raise LinticError, "PR number must be a positive integer"
    end

    def self.validate_repo(repo)
      if repo.nil? || repo.strip.empty?
        raise LinticError, "Repository must be a non-empty string"
      elsif !repo.match?(%r{\A[\w.-]+/[\w.-]+\z})
        raise LinticError, "Repository must be in owner/repo format"
      end
    end
  end

  # Helper class for logger setup
  class LoggerSetup
    def self.create
      logger = Logger.new($stdout)
      logger.level = Logger::INFO
      logger.formatter = proc do |severity, datetime, _progname, msg|
        "LINTIC: [#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
      end
      logger
    end
  end

  # Helper class for GitHub client setup
  class GitHubClientSetup
    def self.create(logger)
      token = ENV.fetch("LINTIC_GITHUB_TOKEN", nil)
      raise LinticError, "LINTIC_GITHUB_TOKEN environment variable is required" unless token

      Octokit::Client.new(access_token: token).tap do |_client|
        # Test the connection
        client.user
        logger.info("GitHub client configured successfully")
      end
    rescue Octokit::Error => e
      raise GitHubError, "GitHub authentication failed: #{e.message}"
    end
  end

  # Helper class for AI client setup
  class AIClientSetup
    def self.create(logger)
      model = ENV.fetch("LINTIC_MODEL", Config::DEFAULT_MODEL)

      OpenAI::Client.new(
        uri_base: ENV.fetch("LINTIC_URI", Config::DEFAULT_OLLAMA_URI),
        request_timeout: Config::REQUEST_TIMEOUT,
        access_token: ENV.fetch("LINTIC_OPENAI_API_KEY", Config::DEFAULT_AI_TOKEN)
      ).tap do |_client|
        logger.info("AI client configured for model: #{model}")
      end
    rescue StandardError => e
      raise AIError, "AI client setup failed: #{e.message}"
    end
  end

  # Main PR processing logic
  class PRProcessor
    def initialize(github_client, ai_client, logger)
      @github_client = github_client
      @ai_client = ai_client
      @logger = logger
    end

    def process(pr_number, repo)
      pr_files = fetch_pr_files(pr_number, repo)
      ruby_files = filter_ruby_files(pr_files)

      return 0 if no_ruby_files?(ruby_files)

      fixes_applied, _summaries = process_ruby_files(ruby_files, repo, pr_number)
      log_results(fixes_applied)
      fixes_applied
    end

    private

    def fetch_pr_files(pr_number, repo)
      @github_client.pull_request_files(repo, pr_number)
    rescue Octokit::NotFound
      raise GitHubError, "PR ##{pr_number} not found in repository #{repo}"
    rescue Octokit::Error => e
      raise GitHubError, "Failed to fetch PR files: #{e.message}"
    end

    def filter_ruby_files(files)
      ruby_files = files.select { |file| RubyFileDetector.ruby_file?(file) }
      @logger.info("Found #{ruby_files.size} Ruby files in PR")
      ruby_files
    end

    def no_ruby_files?(ruby_files)
      return false unless ruby_files.empty?

      @logger.info("No Ruby files found in this PR")
      true
    end

    def process_ruby_files(files, repo, pr_number)
      processor = FileProcessor.new(@github_client, @ai_client, @logger)
      processor.process_files(files, repo, pr_number)
    end

    def log_results(fixes_applied)
      if fixes_applied.positive?
        @logger.info("Successfully processed #{fixes_applied} files with linting fixes")
      else
        @logger.info("No linting errors found or no fixes could be applied")
      end
    end
  end

  # Ruby file detection logic
  class RubyFileDetector
    def self.ruby_file?(file)
      return false if file.status == "removed"
      return true if ruby_extension?(file.filename)
      return false unless File.extname(file.filename).empty?

      # For files without extension, we'd need to check content (simplified here)
      false
    end

    def self.ruby_extension?(filename)
      Config::RUBY_FILE_EXTENSIONS.any? { |ext| filename.end_with?(ext) }
    end
  end

  # Processes individual files for linting errors
  class FileProcessor
    ProcessingContext = Struct.new(:repo, :pr_number, :head_sha, :timestamp, :summaries)

    def initialize(github_client, ai_client, logger)
      @github_client = github_client
      @ai_client = ai_client
      @logger = logger
    end

    def process_files(files, repo, pr_number)
      fixes_applied = 0
      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      summaries = []
      head_sha = fetch_head_sha(repo, pr_number)

      context = ProcessingContext.new(repo, pr_number, head_sha, timestamp, summaries)

      files.each do |file|
        fixes_applied += process_single_file(file, context)
      end

      [fixes_applied, summaries]
    end

    private

    def fetch_head_sha(repo, pr_number)
      pr = @github_client.pull_request(repo, pr_number)
      pr.head.sha
    end

    def process_single_file(file, context)
      @logger.info("Processing file: #{file.filename}")

      content = fetch_file_content(context.repo, file, context.head_sha)
      return 0 if content.strip.empty?

      linting_results = LintingService.run_check(content, @logger)
      return 0 unless linting_errors?(linting_results)

      apply_file_fixes(file, content, linting_results, context)
    rescue StandardError => e
      @logger.error("Failed to process #{file.filename}: #{e.message}")
      0
    end

    def apply_file_fixes(file, content, linting_results, context)
      file_diff = file.patch || ""
      result = AIFixer.fix_errors(@ai_client, content, linting_results, file_diff, @logger)

      return apply_successful_fix(file, result, context) if content_changed?(content, result[:fixed_content])

      log_no_changes_needed(file)
      0
    end

    def apply_successful_fix(file, result, context)
      options = build_fix_options(file, result, context)
      FixApplier.apply(options)

      update_summaries_and_log(file, result, context)
    end

    def build_fix_options(file, result, context)
      {
        github_client: @github_client,
        repo: context.repo,
        file_path: file.filename,
        fixed_content: result[:fixed_content],
        pr_number: context.pr_number,
        timestamp: context.timestamp,
        summaries: context.summaries,
        logger: @logger
      }
    end

    def update_summaries_and_log(file, result, context)
      context.summaries << { file: file.filename, summary: result[:summary] } if result[:summary]
      @logger.info("Applied fixes to #{file.filename}")
      1
    end

    def log_no_changes_needed(file)
      @logger.info("No changes needed for #{file.filename}")
    end

    def fetch_file_content(repo, file, head_sha)
      ContentFetcher.fetch(@github_client, repo, file, head_sha, @logger)
    end

    def linting_errors?(linting_results)
      OffenseExtractor.offenses?(linting_results)
    end

    def content_changed?(original, fixed)
      return false if original.nil? || fixed.nil?

      original.strip != fixed.strip
    end
  end

  # Fetches file content from GitHub
  class ContentFetcher
    def self.fetch(github_client, repo, file, head_sha, logger)
      response = github_client.contents(repo, path: file.filename, ref: head_sha)
      decoded_content = Base64.decode64(response.content)

      if binary_file?(decoded_content)
        logger.warn("Skipping binary file: #{file.filename}")
        return ""
      end

      decoded_content
    rescue Octokit::Error => e
      raise GitHubError, "Failed to fetch file content for #{file.filename}: #{e.message}"
    end

    def self.binary_file?(content)
      content.encoding == Encoding::ASCII_8BIT && !content.valid_encoding?
    end
  end

  # Runs RuboCop linting checks
  class LintingService
    def self.run_check(file_content, logger)
      Tempfile.create([Config::TEMPFILE_PREFIX, ".rb"]) do |tempfile|
        setup_tempfile(tempfile, file_content)
        run_rubocop(tempfile.path)
      end
    rescue JSON::ParserError => e
      logger.error("Failed to parse RuboCop output: #{e.message}")
      raise LintingError, "RuboCop output parsing failed"
    rescue StandardError => e
      logger.error("RuboCop execution failed: #{e.message}")
      raise LintingError, "Linting check failed: #{e.message}"
    end

    def self.setup_tempfile(tempfile, content)
      tempfile.write(content)
      tempfile.close
    end

    def self.run_rubocop(tempfile_path)
      config = RuboCop::ConfigStore.new
      options = create_rubocop_options(tempfile_path)
      runner = RuboCop::Runner.new(options, config)

      with_captured_output do
        runner.run([tempfile_path])
      end
    end

    def self.create_rubocop_options(tempfile_path)
      RuboCop::Options.new.parse([
                                   "--format", "json",
                                   "--force-exclusion",
                                   tempfile_path
                                 ])[0]
    end

    def self.with_captured_output
      stdout_buffer, stderr_buffer = setup_buffers
      original_streams = capture_streams(stdout_buffer, stderr_buffer)

      begin
        yield
      ensure
        restore_streams(original_streams)
      end

      parse_output(stdout_buffer.string)
    end

    def self.setup_buffers
      [StringIO.new, StringIO.new]
    end

    def self.capture_streams(stdout_buffer, stderr_buffer)
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = stdout_buffer
      $stderr = stderr_buffer
      [original_stdout, original_stderr]
    end

    def self.restore_streams(original_streams)
      $stdout, $stderr = original_streams
    end

    def self.parse_output(output)
      return JSON.parse(output) if output && !output.strip.empty?

      { "files" => [{ "offenses" => [] }] }
    end
  end

  # Extracts offenses from linting results
  class OffenseExtractor
    def self.extract(linting_results)
      return [] unless linting_results.is_a?(Hash) && linting_results["files"]

      linting_results["files"].flat_map { |file| file["offenses"] || [] }
    end

    def self.offenses?(linting_results)
      !extract(linting_results).empty?
    end
  end

  # AI-powered error fixing
  class AIFixer
    def self.fix_errors(ai_client, file_content, linting_results, file_diff, logger)
      offenses = OffenseExtractor.extract(linting_results)
      return { fixed_content: file_content, summary: nil } if offenses.empty?

      prompt = PromptBuilder.build_fix_prompt(file_content, offenses, file_diff)
      response = make_ai_request(ai_client, prompt)
      fixed_content = ResponseParser.extract_code(response, logger)
      summary = SummaryGenerator.generate(ai_client, file_content, fixed_content, offenses, logger)

      { fixed_content: fixed_content, summary: summary }
    rescue StandardError => e
      logger.error("AI fix generation failed: #{e.message}")
      raise AIError, "Failed to generate fixes: #{e.message}"
    end

    def self.make_ai_request(ai_client, prompt)
      ai_client.chat(
        parameters: {
          model: ENV.fetch("LINTIC_MODEL", Config::DEFAULT_MODEL),
          messages: [{ role: "user", content: prompt }],
          temperature: Config::AI_TEMPERATURE,
          max_tokens: Config::MAX_FIX_TOKENS
        }
      )
    end
  end

  # Builds prompts for AI requests
  class PromptBuilder
    def self.build_fix_prompt(file_content, offenses, file_diff)
      offense_summary = format_offenses(offenses)
      diff_context = format_diff_context(file_diff)

      prompt_template(file_content, offense_summary, diff_context, file_diff)
    end

    def self.prompt_template(file_content, offense_summary, diff_context, file_diff)
      instructions = build_instructions(file_diff)
      preamble = build_preamble(file_diff)

      <<~PROMPT
        #{preamble}

        #{instructions}

        ORIGINAL CODE:
        ```ruby
        #{file_content}
        ```#{diff_context}

        LINTING ERRORS TO FIX:
        #{offense_summary}

        CORRECTED CODE:
      PROMPT
    end

    def self.build_preamble(file_diff)
      pr_focus = file_diff ? " in the changed lines shown in the diff below" : ""
      main_text = "You are an expert Ruby developer and code reviewer. " \
                  "Please fix the following Ruby code to resolve all RuboCop linting errors."

      "#{main_text}\n\nThis code is from a Pull Request. Focus ONLY on fixing linting errors#{pr_focus}."
    end

    def self.build_instructions(file_diff)
      base_instructions = base_instruction_list
      base_instructions += diff_specific_instructions if file_diff

      "IMPORTANT INSTRUCTIONS:\n#{base_instructions.join("\n")}"
    end

    def self.base_instruction_list
      [
        "1. Return ONLY the corrected Ruby code (the complete fixed file content)",
        "2. Maintain the original functionality and logic exactly",
        "3. Fix ONLY the linting errors specified below",
        "4. Do not modify code that wasn't changed in the PR unless it's necessary to fix linting errors",
        "5. Do not add any explanations, comments, or markdown formatting",
        "6. Preserve the original code structure and indentation style",
        "7. Ensure the output is valid Ruby code that runs without syntax errors"
      ]
    end

    def self.diff_specific_instructions
      ["8. Focus primarily on the lines marked with + in the diff - these are the new/changed lines"]
    end

    def self.format_offenses(offenses)
      offenses.map do |offense|
        line_num = offense.dig("location", "line") || "unknown"
        "- Line #{line_num}: #{offense['message']} (#{offense['cop_name']})"
      end.join("\n")
    end

    def self.format_diff_context(file_diff)
      return "" if !file_diff || file_diff.strip.empty?

      "\n\nPR DIFF (focus on these changes):\n```diff\n#{file_diff}\n```"
    end
  end

  # Parses AI responses to extract code
  class ResponseParser
    def self.extract_code(response, logger)
      content = response.dig("choices", 0, "message", "content")
      raise AIError, "No content received from AI model" unless content

      content = content.strip
      extract_from_markdown(content) || extract_ruby_code(content, logger) || content
    end

    def self.extract_from_markdown(content)
      # Try Ruby markdown block first
      return Regexp.last_match(1).strip if content =~ /```ruby\s*(.+?)\s*```/m
      # Try generic code block
      return Regexp.last_match(1).strip if content =~ /```\s*(.+?)\s*```/m

      nil
    end

    def self.extract_ruby_code(content, logger)
      if ruby_code?(content)
        logger.warn("AI response did not contain a code block, but appears to be Ruby code")
        return content
      end

      logger.warn("AI response format unexpected, using full response")
      content
    end

    def self.ruby_code?(content)
      content.include?("def ") || content.include?("class ") ||
        content.include?("module ") || content.start_with?("#")
    end
  end

  # Generates change summaries
  class SummaryGenerator
    def self.generate(ai_client, file_content, fixed_content, offenses, logger)
      return early_return_message if should_return_early?(file_content, fixed_content)

      prompt = build_summary_prompt(file_content, fixed_content, offenses)
      response = make_summary_request(ai_client, prompt)
      extract_summary_content(response)
    rescue StandardError => e
      logger.error("Failed to generate change summary: #{e.message}")
      "No summary available due to an error"
    end

    def self.should_return_early?(file_content, fixed_content)
      file_content.strip.empty? || fixed_content.strip.empty?
    end

    def self.early_return_message
      "No summary available - no content provided"
    end

    def self.build_summary_prompt(file_content, fixed_content, offenses)
      truncated_original = truncate_content(file_content)
      truncated_fixed = truncate_content(fixed_content)
      formatted_offenses = format_offenses_for_summary(offenses)

      summary_prompt_template(truncated_original, truncated_fixed, formatted_offenses)
    end

    def self.summary_prompt_template(truncated_original, truncated_fixed, formatted_offenses)
      instructions = summary_instructions
      preamble = build_summary_preamble
      code_sections = build_code_sections(truncated_original, truncated_fixed)

      <<~PROMPT
        #{preamble}

        #{instructions}

        #{code_sections}

        LINTING ERRORS FIXED:
        #{formatted_offenses}

        Please provide a markdown-formatted summary of the changes:
      PROMPT
    end

    def self.build_summary_preamble
      <<~PREAMBLE
        You are a code reviewer. Please provide a concise, markdown-formatted summary of the changes made to fix the following linting errors.
      PREAMBLE
    end

    def self.build_code_sections(truncated_original, truncated_fixed)
      original_section = "ORIGINAL CODE:\n```ruby\n#{truncated_original}\n```"
      fixed_section = "FIXED CODE:\n```ruby\n#{truncated_fixed}\n```"

      "#{original_section}\n\n#{fixed_section}"
    end

    def self.summary_instructions
      [
        "1. Focus on explaining WHAT was changed and WHY",
        "2. Use bullet points for each significant change",
        "3. Keep it brief but informative (max 200 words)",
        "4. Use technical but clear language",
        "5. Format in markdown",
        "6. Include the cop names in technical terms",
        "7. Group similar changes together",
        "8. Only mention actual changes made"
      ].join("\n")
    end

    def self.truncate_content(content)
      return content if content.length <= 2000

      "#{content[0..2000]}\n... (truncated)"
    end

    def self.format_offenses_for_summary(offenses)
      offenses.map do |offense|
        line_num = offense.dig("location", "line") || "unknown"
        "- Line #{line_num}: #{offense['message']} (#{offense['cop_name']})"
      end.join("\n")
    end

    def self.make_summary_request(ai_client, prompt)
      ai_client.chat(
        parameters: {
          model: ENV.fetch("LINTIC_MODEL", Config::DEFAULT_MODEL),
          messages: [{ role: "user", content: prompt }],
          temperature: Config::AI_TEMPERATURE,
          max_tokens: Config::MAX_SUMMARY_TOKENS
        }
      )
    end

    def self.extract_summary_content(response)
      content = response.dig("choices", 0, "message", "content")
      content&.strip || "No summary available"
    end
  end

  # Applies fixes to GitHub
  class FixApplier
    FixContext = Struct.new(:github_client, :repo, :file_path, :fixed_content, :pr_number, :timestamp, :summaries,
                            :logger)

    def self.apply(options)
      context = FixContext.new(
        options[:github_client], options[:repo], options[:file_path], options[:fixed_content],
        options[:pr_number], options[:timestamp], options[:summaries], options[:logger]
      )

      execute_fix_workflow(context)
    end

    def self.execute_fix_workflow(context)
      branch_name = create_branch(context)
      update_file_content(context, branch_name)
      create_pull_request(context, branch_name)
    end

    def self.create_branch(context)
      BranchCreator.create(context.github_client, context.repo, context.pr_number, context.timestamp, context.logger)
    end

    def self.update_file_content(context, branch_name)
      FileUpdater.update(
        github_client: context.github_client,
        repo: context.repo,
        branch_name: branch_name,
        file_path: context.file_path,
        fixed_content: context.fixed_content
      )
    end

    def self.create_pull_request(context, branch_name)
      pr_options = {
        github_client: context.github_client,
        repo: context.repo,
        branch_name: branch_name,
        original_pr_number: context.pr_number,
        summaries: context.summaries,
        logger: context.logger
      }
      PRCreator.create(pr_options)
    end
  end

  # Creates fix branches
  class BranchCreator
    def self.create(github_client, repo, pr_number, timestamp, logger)
      original_pr = github_client.pull_request(repo, pr_number)
      branch_name = generate_branch_name(pr_number, timestamp)

      create_branch_ref(github_client, repo, branch_name, original_pr, logger)
    rescue Octokit::Error => e
      raise GitHubError, "Failed to create branch: #{e.message}"
    end

    def self.generate_branch_name(pr_number, timestamp)
      "#{Config::BRANCH_PREFIX}-#{pr_number}-#{timestamp}"
    end

    def self.create_branch_ref(github_client, repo, branch_name, original_pr, logger)
      base_branch = original_pr.head.ref
      base_sha = original_pr.head.sha

      github_client.create_ref(repo, "refs/heads/#{branch_name}", base_sha)
      logger.info("Created branch: #{branch_name} from #{base_branch}")
      branch_name
    end
  end

  # Updates file content
  class FileUpdater
    def self.update(github_client:, repo:, branch_name:, file_path:, fixed_content:)
      current_file = github_client.contents(repo, path: file_path, ref: branch_name)

      github_client.update_contents(
        repo,
        file_path,
        Config::COMMIT_MESSAGE,
        current_file.sha,
        fixed_content,
        branch: branch_name
      )
    rescue Octokit::Error => e
      raise GitHubError, "Failed to update file content: #{e.message}"
    end
  end

  # Creates fix pull requests
  class PRCreator
    PRContext = Struct.new(:github_client, :repo, :branch_name, :original_pr_number, :summaries, :logger)

    def self.create(options)
      context = PRContext.new(
        options[:github_client], options[:repo], options[:branch_name],
        options[:original_pr_number], options[:summaries], options[:logger]
      )

      create_pull_request(context)
    end

    def self.create_pull_request(context)
      original_pr = fetch_original_pr(context)
      pr_details = build_pr_details(context, original_pr)

      create_and_log_pr(context, pr_details)
    rescue Octokit::Error => e
      raise GitHubError, "Failed to create pull request: #{e.message}"
    end

    def self.fetch_original_pr(context)
      context.github_client.pull_request(context.repo, context.original_pr_number)
    end

    def self.build_pr_details(context, original_pr)
      {
        base_branch: original_pr.head.ref,
        title: "[LINTIC] 🧹 Fix linting errors (PR ##{context.original_pr_number})",
        body: PRBodyBuilder.build(context.original_pr_number, context.summaries)
      }
    end

    def self.create_and_log_pr(context, pr_details)
      pr = context.github_client.create_pull_request(
        context.repo, pr_details[:base_branch], context.branch_name, pr_details[:title], pr_details[:body]
      )
      context.logger.info("Created fix PR: #{pr.html_url}")
      pr
    end
  end

  # Builds PR body content
  class PRBodyBuilder
    def self.build(original_pr_number, summaries)
      changes_summary = build_changes_summary(summaries)
      header = build_header(original_pr_number)
      usage_instructions = build_usage_instructions
      footer = build_footer

      "#{header}\n\n### What was fixed:\n#{changes_summary}\n\n#{usage_instructions}\n\n#{footer}"
    end

    def self.build_header(original_pr_number)
      "## 🤖 Automated Linting Fixes\n\n" \
        "This PR was automatically created by **Lintic** to fix linting errors found in PR ##{original_pr_number}."
    end

    def self.build_usage_instructions
      "### How to use:\n" \
        "1. Review the changes in this PR\n" \
        "2. If satisfied, merge this PR into your feature branch\n" \
        "3. Your original PR will then have clean, linted code"
    end

    def self.build_footer
      "---\n*Generated automatically by [Lintic](https://github.com/shindi-renuo/lintic) 🚀*"
    end

    def self.build_changes_summary(summaries)
      return default_changes_summary if summaries.empty?

      summaries.map do |summary|
        "### #{summary[:file]}\n#{summary[:summary]}"
      end.join("\n\n")
    end

    def self.default_changes_summary
      "- RuboCop linting violations\n- Code style improvements\n- Best practices enforcement"
    end
  end

  # GitHub summary writer
  class GitHubSummaryWriter
    def self.write(message)
      return unless ENV["GITHUB_STEP_SUMMARY"]

      File.open(ENV.fetch("GITHUB_STEP_SUMMARY", nil), "a") { |f| f.puts message }
    rescue StandardError => e
      warn("Failed to write to GitHub step summary: #{e.message}")
    end
  end
end

# CLI execution
if $PROGRAM_NAME == __FILE__
  begin
    is_ci = ENV["CI"] == "true" || ENV["GITHUB_ACTIONS"] == "true"
    required_vars = %w[LINTIC_GITHUB_TOKEN LINTIC_GITHUB_REPO LINTIC_GITHUB_PR_NUMBER]
    missing_vars = required_vars.select { |var| ENV[var].nil? || ENV[var].empty? }

    unless missing_vars.empty?
      puts "❌ Missing required environment variables: #{missing_vars.join(', ')}"
      puts "Please check your .env file or environment configuration."
      exit 1
    end

    lintic = Lintic.new
    pr_number = ENV.fetch("LINTIC_GITHUB_PR_NUMBER").to_i
    repo = ENV.fetch("LINTIC_GITHUB_REPO")

    if pr_number <= 0
      puts "❌ LINTIC_GITHUB_PR_NUMBER must be a positive integer"
      exit 1
    end

    if is_ci
      Lintic::GitHubSummaryWriter.write("::group::🚀 Starting Lintic for PR ##{pr_number} in #{repo}")
    else
      puts "🚀 Starting Lintic for PR ##{pr_number} in #{repo}"
    end

    result = lintic.process_pr(pr_number, repo)

    if is_ci
      Lintic::GitHubSummaryWriter.write("::endgroup::")

      if result&.positive?
        Lintic::GitHubSummaryWriter.write(
          "::notice title=Lintic Success::Successfully processed #{result} files with linting fixes"
        )
      else
        Lintic::GitHubSummaryWriter.write("::notice title=Lintic Complete::No linting errors found or fixes needed")
      end
    end

    puts "✅ Lintic completed successfully!"
  rescue Lintic::LinticError => e
    if is_ci
      Lintic::GitHubSummaryWriter.write("::error title=Lintic Error::#{e.message}")
    else
      puts "❌ Lintic Error: #{e.message}"
    end
    exit 1
  rescue StandardError => e
    if is_ci
      Lintic::GitHubSummaryWriter.write("::error title=Unexpected Error::#{e.message}")
    else
      puts "❌ Unexpected Error: #{e.message}"
      puts "Please check your configuration and try again."
    end
    exit 1
  end
end
