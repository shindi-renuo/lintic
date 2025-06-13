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

  def initialize
    @logger = setup_logger
    @github_client = setup_github_client
    @ai_client = setup_ai_client
    @logger.info('Lintic initialized successfully')
  end

  def process_pr(pr_number, repo)
    @logger.info("Processing PR ##{pr_number} in #{repo}")

    begin
      pr_files = fetch_pr_files(pr_number, repo)
      ruby_files = filter_ruby_files(pr_files)

      if ruby_files.empty?
        @logger.info('No Ruby files found in this PR')
        return 0
      end

      fixes_applied = process_ruby_files(ruby_files, repo, pr_number)

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
    model = ENV.fetch('LINTIC_OLLAMA_MODEL', 'codellama')

    OpenAI::Client.new(
      uri_base: ENV.fetch('LINTIC_OLLAMA_URI', 'http://localhost:11434/v1/'),
      request_timeout: 120,
      access_token: ENV.fetch('LINTIC_OPENAI_API_KEY', 'ollama')
    ).tap do |client|
      @logger.info("AI client configured for model: #{model}")
    end
  rescue StandardError => e
    raise AIError, "AI client setup failed: #{e.message}"
  end

  def fetch_pr_files(pr_number, repo)
    @github_client.pull_request_files(repo, pr_number)
  rescue Octokit::Error => e
    raise GitHubError, "Failed to fetch PR files: #{e.message}"
  end

  def filter_ruby_files(files)
    ruby_files = files.select { |file| file.filename.end_with?('.rb') }
    @logger.info("Found #{ruby_files.size} Ruby files in PR")
    ruby_files
  end

  def process_ruby_files(files, repo, pr_number)
    fixes_applied = 0
    timestamp = Time.now.strftime('%Y%m%d%H%M%S')

    # Get PR details to obtain the head commit SHA
    pr = @github_client.pull_request(repo, pr_number)
    head_sha = pr.head.sha

    files.each do |file|
      @logger.info("Processing file: #{file.filename}")

      begin
        content = fetch_file_content(repo, file, head_sha)
        linting_results = run_linting_check(content)

        if has_linting_errors?(linting_results)
          file_diff = get_file_diff(file)
          fixed_content = fix_linting_errors(content, linting_results, file_diff)

          if content_changed?(content, fixed_content)
            apply_fixes(repo, file.filename, fixed_content, pr_number, timestamp)
            fixes_applied += 1
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

    fixes_applied
  end

  def fetch_file_content(repo, file, head_sha)
    # Get the raw content of the file from the PR head commit
    response = @github_client.contents(repo, path: file.filename, ref: head_sha)
    Base64.decode64(response.content)
  rescue Octokit::Error => e
    raise GitHubError, "Failed to fetch file content for #{file.filename}: #{e.message}"
  end

  def get_file_diff(file)
    # Return the patch/diff content which shows only the changes
    file.patch
  end

  def run_linting_check(file_content)
    Tempfile.create(['lintic_check', '.rb']) do |tempfile|
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
    return [] unless linting_results['files']

    linting_results['files'].flat_map { |file| file['offenses'] || [] }
  end

  def fix_linting_errors(file_content, linting_results, file_diff = nil)
    offenses = extract_offenses(linting_results)
    return file_content if offenses.empty?

    prompt = build_fix_prompt(file_content, offenses, file_diff)

    response = @ai_client.chat(
      parameters: {
        model: ENV.fetch('LINTIC_OLLAMA_MODEL', 'codellama'),
        messages: [{ role: 'user', content: prompt }],
        temperature: 0.1,
        max_tokens: 4000
      }
    )

    extract_fixed_code(response)
  rescue StandardError => e
    @logger.error("AI fix generation failed: #{e.message}")
    raise AIError, "Failed to generate fixes: #{e.message}"
  end

  def build_fix_prompt(file_content, offenses, file_diff = nil)
    offense_summary = offenses.map do |offense|
      "- Line #{offense['location']['line']}: #{offense['message']} (#{offense['cop_name']})"
    end.join("\n")

    diff_context = file_diff ? "\n\nPR DIFF (focus on these changes):\n```diff\n#{file_diff}\n```" : ''

    <<~PROMPT
      You are an expert Ruby developer and code reviewer. Please fix the following Ruby code to resolve all RuboCop linting errors.

      This code is from a Pull Request. Focus ONLY on fixing linting errors in the changed lines shown in the diff below.

      IMPORTANT INSTRUCTIONS:
      1. Return ONLY the corrected Ruby code (the complete fixed file content)
      2. Maintain the original functionality and logic
      3. Fix ONLY the linting errors in the changed lines (shown in the diff)
      4. Do not modify code that wasn't changed in the PR unless it's necessary to fix linting errors
      5. Do not add any explanations or comments about the changes
      6. Preserve the original code structure as much as possible
      7. Focus on the lines marked with + in the diff - these are the new/changed lines

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

    # Try to extract from Ruby markdown block first
    return Regexp.last_match(1).strip if content =~ /```ruby\s*(.+?)\s*```/m

    # Try to extract from generic code block
    return Regexp.last_match(1).strip if content =~ /```\s*(.+?)\s*```/m

    # If no code block, return the content as-is (but log a warning)
    @logger.warn('AI response did not contain a code block, using full response')
    content.strip
  end

  def content_changed?(original, fixed)
    original.strip != fixed.strip
  end

  def apply_fixes(repo, file_path, fixed_content, pr_number, timestamp)
    branch_name = create_fix_branch(repo, pr_number, timestamp)
    update_file_content(repo, branch_name, file_path, fixed_content)
    create_fix_pull_request(repo, branch_name, pr_number)
  end

  def create_fix_branch(repo, pr_number, timestamp)
    base_branch = get_default_branch(repo)
    branch_name = "lintic/fix-pr-#{pr_number}-#{timestamp}"

    base_sha = @github_client.ref(repo, "heads/#{base_branch}").object.sha
    @github_client.create_ref(repo, "refs/heads/#{branch_name}", base_sha)

    @logger.info("Created branch: #{branch_name}")
    branch_name
  rescue Octokit::Error => e
    raise GitHubError, "Failed to create branch: #{e.message}"
  end

  def get_default_branch(repo)
    @github_client.repository(repo).default_branch
  rescue Octokit::Error => e
    raise GitHubError, "Failed to get default branch: #{e.message}"
  end

  def update_file_content(repo, branch_name, file_path, fixed_content)
    # Get the current file to obtain its SHA
    current_file = @github_client.contents(repo, path: file_path, ref: branch_name)

    @github_client.update_contents(
      repo,
      file_path,
      '🤖 Fix linting errors with Lintic',
      current_file.sha,
      fixed_content,
      branch: branch_name
    )
  rescue Octokit::Error => e
    raise GitHubError, "Failed to update file content: #{e.message}"
  end

  def create_fix_pull_request(repo, branch_name, original_pr_number)
    base_branch = get_default_branch(repo)

    title = "🧹 Fix linting errors (PR ##{original_pr_number})"
    body = build_pr_body(original_pr_number)

    pr = @github_client.create_pull_request(repo, base_branch, branch_name, title, body)
    @logger.info("Created fix PR: #{pr.html_url}")
    pr
  rescue Octokit::Error => e
    raise GitHubError, "Failed to create pull request: #{e.message}"
  end

  def build_pr_body(original_pr_number)
    <<~BODY
      ## 🤖 Automated Linting Fixes

      This PR was automatically created by **Lintic** to fix linting errors found in PR ##{original_pr_number}.

      ### What was fixed:
      - RuboCop linting violations
      - Code style improvements
      - Best practices enforcement

      ### How to use:
      1. Review the changes in this PR
      2. If satisfied, merge this PR into your feature branch
      3. Your original PR will then have clean, linted code

      ---
      *Generated automatically by [Lintic](https://github.com/shindi-renuo/lintic) 🚀*
    BODY
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

    if is_ci
      puts "::group::🚀 Starting Lintic for PR ##{pr_number} in #{repo}"
    else
      puts "🚀 Starting Lintic for PR ##{pr_number} in #{repo}"
    end

    result = lintic.process_pr(pr_number, repo)

    if is_ci
      puts '::endgroup::'

      if result && result > 0
        puts "::notice title=Lintic Success::Successfully processed #{result} files with linting fixes"
      else
        puts '::notice title=Lintic Complete::No linting errors found or fixes needed'
      end
    end

    puts '✅ Lintic completed successfully!'
  rescue Lintic::LinticError => e
    if is_ci
      puts "::error title=Lintic Error::#{e.message}"
    else
      puts "❌ Lintic Error: #{e.message}"
    end
    exit 1
  rescue StandardError => e
    if is_ci
      puts "::error title=Unexpected Error::#{e.message}"
    else
      puts "❌ Unexpected Error: #{e.message}"
      puts 'Please check your configuration and try again.'
    end
    exit 1
  end
end
