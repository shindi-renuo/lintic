# frozen_string_literal: true

require 'dotenv'
require 'octokit'
require 'ruby/openai'
require 'json'
require 'tempfile'
require 'stringio'
require 'base64'
require 'logger'
require 'rubocop'

Dotenv.load

class Lintic
  class LinticError < StandardError; end
  class GitHubError < LinticError; end
  class LintingError < LinticError; end
  class AIError < LinticError; end

  # Constants
  DEFAULT_MODEL = 'qwen2.5-coder:1.5b'
  DEFAULT_OLLAMA_URI = 'http://localhost:11434/v1/'
  DEFAULT_AI_TOKEN = 'ollama'
  REQUEST_TIMEOUT = 120
  AI_TEMPERATURE = 0.1
  MAX_SUMMARY_TOKENS = 1000
  MAX_FIX_TOKENS = 4000
  BRANCH_PREFIX = 'lintic/fix-pr'
  COMMIT_MESSAGE = '🤖 Fix linting errors with Lintic'
  TEMPFILE_PREFIX = 'lintic_check'
  RUBY_FILE_EXTENSIONS = %w[.rb .rake .gemspec].freeze
  RUBY_SHEBANG_PATTERN = /\A#!.*ruby/

  def initialize
    @logger = setup_logger
    @github_client = setup_github_client
    @ai_client = setup_ai_client
    @logger.info('Lintic initialized successfully')
  end

  def process_pr(pr_number, repo)
    validate_inputs(pr_number, repo)
    @logger.info("Processing PR ##{pr_number} in #{repo}")

    begin
      pr_files = fetch_pr_files(pr_number, repo)
      ruby_files = filter_ruby_files(pr_files)

      if ruby_files.empty?
        @logger.info('No Ruby files found in this PR')
        return 0
      end

      fixes_applied, summaries = process_ruby_files(ruby_files, repo, pr_number)

      if fixes_applied > 0
        @logger.info("Successfully processed #{fixes_applied} files with linting fixes")
      else
        @logger.info('No linting errors found or no fixes could be applied')
      end

      fixes_applied
    rescue StandardError => e
      @logger.error("Failed to process PR: #{e.message}")
      raise LinticError, "PR processing failed: #{e.message}"
    end
  end

  private

  def validate_inputs(pr_number, repo)
    raise LinticError, 'PR number must be a positive integer' unless pr_number.is_a?(Integer) && pr_number.positive?
    raise LinticError, 'Repository must be a non-empty string' if repo.nil? || repo.strip.empty?
    raise LinticError, 'Repository must be in owner/repo format' unless repo.match?(%r{\A[\w.-]+/[\w.-]+\z})
  end

  def setup_logger
    logger = Logger.new($stdout)
    logger.level = Logger::INFO
    logger.formatter = proc do |severity, datetime, progname, msg|
      "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
    end
    logger
  end

  def setup_github_client
    token = ENV['LINTIC_GITHUB_TOKEN']
    raise LinticError, 'LINTIC_GITHUB_TOKEN environment variable is required' unless token

    Octokit::Client.new(access_token: token).tap do |client|
      # Test the connection
      client.user
      @logger.info('GitHub client configured successfully')
    end
  rescue Octokit::Error => e
    raise GitHubError, "GitHub authentication failed: #{e.message}"
  end

  def setup_ai_client
    model = ENV.fetch('LINTIC_MODEL', DEFAULT_MODEL)

    OpenAI::Client.new(
      uri_base: ENV.fetch('LINTIC_URI', DEFAULT_OLLAMA_URI),
      request_timeout: REQUEST_TIMEOUT,
      access_token: ENV.fetch('LINTIC_OPENAI_API_KEY', DEFAULT_AI_TOKEN)
    ).tap do |client|
      @logger.info("AI client configured for model: #{model}")
    end
  rescue StandardError => e
    raise AIError, "AI client setup failed: #{e.message}"
  end

  def fetch_pr_files(pr_number, repo)
    @github_client.pull_request_files(repo, pr_number)
  rescue Octokit::NotFound
    raise GitHubError, "PR ##{pr_number} not found in repository #{repo}"
  rescue Octokit::Error => e
    raise GitHubError, "Failed to fetch PR files: #{e.message}"
  end

  def filter_ruby_files(files)
    ruby_files = files.select { |file| ruby_file?(file) }
    @logger.info("Found #{ruby_files.size} Ruby files in PR")
    ruby_files
  end

  def ruby_file?(file)
    return false if file.status == 'removed'

    # Check file extension
    return true if RUBY_FILE_EXTENSIONS.any? { |ext| file.filename.end_with?(ext) }

    # Check for Ruby shebang in the first line if file has no extension
    return false unless File.extname(file.filename).empty?

    # For files without extension, we'd need to check content (simplified here)
    # In a real implementation, you might want to fetch a small portion of the file
    false
  end

  def process_ruby_files(files, repo, pr_number)
    fixes_applied = 0
    timestamp = Time.now.strftime('%Y%m%d%H%M%S')
    summaries = []

    # Get PR details to obtain the head commit SHA
    pr = @github_client.pull_request(repo, pr_number)
    head_sha = pr.head.sha

    files.each do |file|
      @logger.info("Processing file: #{file.filename}")

      begin
        content = fetch_file_content(repo, file, head_sha)
        next if content.strip.empty?

        linting_results = run_linting_check(content)

        if has_linting_errors?(linting_results)
          file_diff = get_file_diff(file)
          result = fix_linting_errors(content, linting_results, file_diff)

          if content_changed?(content, result[:fixed_content])
            apply_fixes(repo, file.filename, result[:fixed_content], pr_number, timestamp, summaries)
            fixes_applied += 1
            summaries << { file: file.filename, summary: result[:summary] } if result[:summary]
            @logger.info("Applied fixes to #{file.filename}")
          else
            @logger.info("No changes needed for #{file.filename}")
          end
        else
          @logger.info("No linting errors found in #{file.filename}")
        end
      rescue StandardError => e
        @logger.error("Failed to process #{file.filename}: #{e.message}")
        # Continue with other files
      end
    end

    [fixes_applied, summaries]
  end

  def fetch_file_content(repo, file, head_sha)
    # Get the raw content of the file from the PR head commit
    response = @github_client.contents(repo, path: file.filename, ref: head_sha)
    decoded_content = Base64.decode64(response.content)

    # Validate that content is not binary
    if decoded_content.encoding == Encoding::ASCII_8BIT && !decoded_content.valid_encoding?
      @logger.warn("Skipping binary file: #{file.filename}")
      return ''
    end

    decoded_content
  rescue Octokit::Error => e
    raise GitHubError, "Failed to fetch file content for #{file.filename}: #{e.message}"
  end

  def get_file_diff(file)
    # Return the patch/diff content which shows only the changes
    file.patch || ''
  end

  def run_linting_check(file_content)
    Tempfile.create([TEMPFILE_PREFIX, '.rb']) do |tempfile|
      tempfile.write(file_content)
      tempfile.close

      config = RuboCop::ConfigStore.new
      options = RuboCop::Options.new.parse([
                                             '--format', 'json',
                                             '--force-exclusion',
                                             tempfile.path
                                           ])[0]

      runner = RuboCop::Runner.new(options, config)

      # Capture output
      original_stdout = $stdout
      original_stderr = $stderr
      stdout_buffer = StringIO.new
      stderr_buffer = StringIO.new

      begin
        $stdout = stdout_buffer
        $stderr = stderr_buffer
        runner.run([tempfile.path])
      ensure
        $stdout = original_stdout
        $stderr = original_stderr
      end

      output = stdout_buffer.string
      return JSON.parse(output) if output && !output.strip.empty?

      # Fallback if JSON output is empty
      { 'files' => [{ 'offenses' => [] }] }
    end
  rescue JSON::ParserError => e
    @logger.error("Failed to parse RuboCop output: #{e.message}")
    raise LintingError, 'RuboCop output parsing failed'
  rescue StandardError => e
    @logger.error("RuboCop execution failed: #{e.message}")
    raise LintingError, "Linting check failed: #{e.message}"
  end

  def has_linting_errors?(linting_results)
    offenses = extract_offenses(linting_results)
    !offenses.empty?
  end

  def extract_offenses(linting_results)
    return [] unless linting_results.is_a?(Hash) && linting_results['files']

    linting_results['files'].flat_map { |file| file['offenses'] || [] }
  end

  def generate_change_summary(file_content, fixed_content, offenses)
    return 'No summary available - no content provided' if file_content.strip.empty? || fixed_content.strip.empty?

    prompt = <<~PROMPT
      You are a code reviewer. Please provide a concise, markdown-formatted summary of the changes made to fix the following linting errors.

      IMPORTANT INSTRUCTIONS:
      1. Focus on explaining WHAT was changed and WHY
      2. Use bullet points for each significant change
      3. Keep it brief but informative (max 200 words)
      4. Use technical but clear language
      5. Format in markdown
      6. Include the cop names in technical terms
      7. Group similar changes together
      8. Only mention actual changes made

      ORIGINAL CODE:
      ```ruby
      #{file_content[0..2000]}#{file_content.length > 2000 ? "\n... (truncated)" : ''}
      ```

      FIXED CODE:
      ```ruby
      #{fixed_content[0..2000]}#{fixed_content.length > 2000 ? "\n... (truncated)" : ''}
      ```

      LINTING ERRORS FIXED:
      #{offenses.map { |o| "- Line #{o.dig('location', 'line') || 'unknown'}: #{o['message']} (#{o['cop_name']})" }.join("\n")}

      Please provide a markdown-formatted summary of the changes:
    PROMPT

    response = @ai_client.chat(
      parameters: {
        model: ENV.fetch('LINTIC_MODEL', DEFAULT_MODEL),
        messages: [{ role: 'user', content: prompt }],
        temperature: AI_TEMPERATURE,
        max_tokens: MAX_SUMMARY_TOKENS
      }
    )

    content = response.dig('choices', 0, 'message', 'content')
    content&.strip || 'No summary available'
  rescue StandardError => e
    @logger.error("Failed to generate change summary: #{e.message}")
    'No summary available due to an error'
  end

  def fix_linting_errors(file_content, linting_results, file_diff = nil)
    offenses = extract_offenses(linting_results)
    return { fixed_content: file_content, summary: nil } if offenses.empty?

    prompt = build_fix_prompt(file_content, offenses, file_diff)

    response = @ai_client.chat(
      parameters: {
        model: ENV.fetch('LINTIC_MODEL', DEFAULT_MODEL),
        messages: [{ role: 'user', content: prompt }],
        temperature: AI_TEMPERATURE,
        max_tokens: MAX_FIX_TOKENS
      }
    )

    fixed_content = extract_fixed_code(response)
    summary = generate_change_summary(file_content, fixed_content, offenses)

    { fixed_content: fixed_content, summary: summary }
  rescue StandardError => e
    @logger.error("AI fix generation failed: #{e.message}")
    raise AIError, "Failed to generate fixes: #{e.message}"
  end

  def build_fix_prompt(file_content, offenses, file_diff = nil)
    offense_summary = offenses.map do |offense|
      line_num = offense.dig('location', 'line') || 'unknown'
      "- Line #{line_num}: #{offense['message']} (#{offense['cop_name']})"
    end.join("\n")

    diff_context = if file_diff && !file_diff.strip.empty?
                     "\n\nPR DIFF (focus on these changes):\n```diff\n#{file_diff}\n```"
                   else
                     ''
                   end

    <<~PROMPT
      You are an expert Ruby developer and code reviewer. Please fix the following Ruby code to resolve all RuboCop linting errors.

      This code is from a Pull Request. Focus ONLY on fixing linting errors#{file_diff ? ' in the changed lines shown in the diff below' : ''}.

      IMPORTANT INSTRUCTIONS:
      1. Return ONLY the corrected Ruby code (the complete fixed file content)
      2. Maintain the original functionality and logic exactly
      3. Fix ONLY the linting errors specified below
      4. Do not modify code that wasn't changed in the PR unless it's necessary to fix linting errors
      5. Do not add any explanations, comments, or markdown formatting
      6. Preserve the original code structure and indentation style
      7. Ensure the output is valid Ruby code that runs without syntax errors
      #{'8. Focus primarily on the lines marked with + in the diff - these are the new/changed lines' if file_diff}

      ORIGINAL CODE:
      ```ruby
      #{file_content}
      ```#{diff_context}

      LINTING ERRORS TO FIX:
      #{offense_summary}

      CORRECTED CODE:
    PROMPT
  end

  def extract_fixed_code(response)
    content = response.dig('choices', 0, 'message', 'content')

    raise AIError, 'No content received from AI model' unless content

    # Clean up the content first
    content = content.strip

    # Try to extract from Ruby markdown block first
    return Regexp.last_match(1).strip if content =~ /```ruby\s*(.+?)\s*```/m

    # Try to extract from generic code block
    return Regexp.last_match(1).strip if content =~ /```\s*(.+?)\s*```/m

    # If no code block, check if the entire response looks like Ruby code
    if content.include?('def ') || content.include?('class ') || content.include?('module ') || content.start_with?('#')
      @logger.warn('AI response did not contain a code block, but appears to be Ruby code')
      return content
    end

    # Last resort: return content as-is but log a warning
    @logger.warn('AI response format unexpected, using full response')
    content
  end

  def content_changed?(original, fixed)
    return false if original.nil? || fixed.nil?

    original.strip != fixed.strip
  end

  def apply_fixes(repo, file_path, fixed_content, pr_number, timestamp, summaries = [])
    branch_name = create_fix_branch(repo, pr_number, timestamp)
    update_file_content(repo, branch_name, file_path, fixed_content)
    create_fix_pull_request(repo, branch_name, pr_number, summaries)
  end

  def create_fix_branch(repo, pr_number, timestamp)
    # Get the original PR to find its head branch and SHA
    original_pr = @github_client.pull_request(repo, pr_number)
    base_branch = original_pr.head.ref
    base_sha = original_pr.head.sha

    branch_name = "#{BRANCH_PREFIX}-#{pr_number}-#{timestamp}"

    @github_client.create_ref(repo, "refs/heads/#{branch_name}", base_sha)

    @logger.info("Created branch: #{branch_name} from #{base_branch}")
    branch_name
  rescue Octokit::Error => e
    raise GitHubError, "Failed to create branch: #{e.message}"
  end

  def update_file_content(repo, branch_name, file_path, fixed_content)
    # Get the current file to obtain its SHA
    current_file = @github_client.contents(repo, path: file_path, ref: branch_name)

    @github_client.update_contents(
      repo,
      file_path,
      COMMIT_MESSAGE,
      current_file.sha,
      fixed_content,
      branch: branch_name
    )
  rescue Octokit::Error => e
    raise GitHubError, "Failed to update file content: #{e.message}"
  end

  def create_fix_pull_request(repo, branch_name, original_pr_number, summaries = [])
    # Get the original PR to find its head branch
    original_pr = @github_client.pull_request(repo, original_pr_number)
    base_branch = original_pr.head.ref

    title = "[LINTIC] 🧹 Fix linting errors (PR ##{original_pr_number})"
    body = build_pr_body(original_pr_number, summaries)

    pr = @github_client.create_pull_request(repo, base_branch, branch_name, title, body)
    @logger.info("Created fix PR: #{pr.html_url}")
    pr
  rescue Octokit::Error => e
    raise GitHubError, "Failed to create pull request: #{e.message}"
  end

  def build_pr_body(original_pr_number, summaries = [])
    changes_summary = if summaries.any?
                        summaries.map do |summary|
                          <<~SUMMARY
                            ### #{summary[:file]}
                            #{summary[:summary]}
                          SUMMARY
                        end.join("\n\n")
                      else
                        "- RuboCop linting violations\n- Code style improvements\n- Best practices enforcement"
                      end

    <<~BODY
      ## 🤖 Automated Linting Fixes

      This PR was automatically created by **Lintic** to fix linting errors found in PR ##{original_pr_number}.

      ### What was fixed:
      #{changes_summary}

      ### How to use:
      1. Review the changes in this PR
      2. If satisfied, merge this PR into your feature branch
      3. Your original PR will then have clean, linted code

      ---
      *Generated automatically by [Lintic](https://github.com/shindi-renuo/lintic) 🚀*
    BODY
  end

  def write_to_github_summary(message)
    return unless ENV['GITHUB_STEP_SUMMARY']

    File.open(ENV['GITHUB_STEP_SUMMARY'], 'a') { |f| f.puts message }
  rescue StandardError => e
    @logger.warn("Failed to write to GitHub step summary: #{e.message}")
  end
end

# CLI execution
if $PROGRAM_NAME == __FILE__
  begin
    # Check if running in CI environment
    is_ci = ENV['CI'] == 'true' || ENV['GITHUB_ACTIONS'] == 'true'

    # Validate required environment variables
    required_vars = %w[LINTIC_GITHUB_TOKEN LINTIC_GITHUB_REPO LINTIC_GITHUB_PR_NUMBER]
    missing_vars = required_vars.select { |var| ENV[var].nil? || ENV[var].empty? }

    unless missing_vars.empty?
      puts "❌ Missing required environment variables: #{missing_vars.join(', ')}"
      puts 'Please check your .env file or environment configuration.'
      exit 1
    end

    # Initialize and run
    lintic = Lintic.new
    pr_number = ENV.fetch('LINTIC_GITHUB_PR_NUMBER').to_i
    repo = ENV.fetch('LINTIC_GITHUB_REPO')

    # Validate PR number
    if pr_number <= 0
      puts '❌ LINTIC_GITHUB_PR_NUMBER must be a positive integer'
      exit 1
    end

    if is_ci
      lintic.send(:write_to_github_summary, "::group::🚀 Starting Lintic for PR ##{pr_number} in #{repo}")
    else
      puts "🚀 Starting Lintic for PR ##{pr_number} in #{repo}"
    end

    result = lintic.process_pr(pr_number, repo)

    if is_ci
      lintic.send(:write_to_github_summary, '::endgroup::')

      if result && result > 0
        lintic.send(:write_to_github_summary,
                    "::notice title=Lintic Success::Successfully processed #{result} files with linting fixes")
      else
        lintic.send(:write_to_github_summary, '::notice title=Lintic Complete::No linting errors found or fixes needed')
      end
    end

    puts '✅ Lintic completed successfully!'
  rescue Lintic::LinticError => e
    if is_ci
      lintic&.send(:write_to_github_summary, "::error title=Lintic Error::#{e.message}")
    else
      puts "❌ Lintic Error: #{e.message}"
    end
    exit 1
  rescue StandardError => e
    if is_ci
      lintic&.send(:write_to_github_summary, "::error title=Unexpected Error::#{e.message}")
    else
      puts "❌ Unexpected Error: #{e.message}"
      puts 'Please check your configuration and try again.'
    end
    exit 1
  end
end
