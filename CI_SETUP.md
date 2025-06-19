# Setting Up Lintic as a CI Step

This comprehensive guide explains how to integrate Lintic into your GitHub workflow to automatically fix linting errors in pull requests.

## Quick Setup

### Option 1: Use as a GitHub Action (Recommended)

Create `.github/workflows/lintic.yml` in your repository:

```yaml
name: Lintic

on:
  pull_request:
    paths:
      - '**/*.rb'

jobs:
  lint-fix:
    runs-on: ubuntu-latest
    if: github.event.pull_request.head.repo.full_name == github.repository

    steps:
      - uses: actions/checkout@v4

      - name: Fix linting errors with Lintic
        uses: shindi-renuo/lintic@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          ollama-model: qwen2.5-coder:1.5b
          ollama-uri: http://localhost:11434/v1/
          openai-api-key: 'ollama'
```

### Option 2: Manual Setup with Custom Ollama Server

If you have a remote Ollama instance or want more control:

```yaml
name: Lintic - Custom Setup

on:
  pull_request:
    types: [opened, synchronize, reopened]
    paths:
      - '**/*.rb'

permissions:
  contents: write
  pull-requests: write

jobs:
  lintic:
    runs-on: ubuntu-latest
    if: github.event.pull_request.head.repo.full_name == github.repository

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.1

      - name: Install Ruby dependencies
        run: |
          gem install dotenv octokit ruby-openai rubocop

      - name: Set up Ollama
        run: |
          curl -fsSL https://ollama.ai/install.sh | sh
          ollama serve &
          sleep 10
          ollama pull qwen2.5-coder:1.5b

      - name: Download and run Lintic
                  env:
            LINTIC_GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
            LINTIC_GITHUB_REPO: ${{ github.repository }}
            LINTIC_GITHUB_PR_NUMBER: ${{ github.event.pull_request.number }}
            LINTIC_MODEL: qwen2.5-coder:1.5b
            LINTIC_URI: http://localhost:11434/v1/
            LINTIC_OPENAI_API_KEY: ollama
        run: |
          curl -o lintic.rb https://raw.githubusercontent.com/shindi-renuo/lintic/main/main.rb
          ruby lintic.rb
```

## Configuration Options

### Action Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `github-token` | GitHub token for API access | Yes | `${{ github.token }}` |
| `ollama-model` | AI model to use for fixing | No | `qwen2.5-coder:1.5b` |
| `ollama-uri` | Ollama server URI | No | `http://localhost:11434/v1/` |
| `openai-api-key` | OpenAI API key (if not using Ollama) | No | `ollama` |
| `ruby-version` | Ruby version to use | No | `3.1` |

### Action Outputs

| Output | Description |
|--------|-------------|
| `fixes-applied` | Number of files that were fixed |
| `pr-created` | URL of the created fix PR (if any) |

### Environment Variables

When running manually or in custom setups, these environment variables are used:

| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| `LINTIC_GITHUB_TOKEN` | GitHub authentication token | ✅ | - |
| `LINTIC_GITHUB_REPO` | Repository in format `owner/repo` | ✅ | - |
| `LINTIC_GITHUB_PR_NUMBER` | Pull request number to process | ✅ | - |
| `LINTIC_MODEL` | AI model to use | ❌ | `codellama` |
| `LINTIC_URI` | Server URL for AI model | ❌ | `http://localhost:11434/v1/` |
| `LINTIC_OPENAI_API_KEY` | OpenAI API key | ❌ | `ollama` |

## How It Works

1. **🔍 Trigger**: The workflow triggers when a PR is opened, updated, or reopened and contains Ruby files
2. **🛠️ Setup**: Installs Ruby dependencies and Ollama with the specified AI model
3. **📁 Analysis**: Fetches changed Ruby files from the PR and runs RuboCop linting
4. **🤖 AI Fix**: Uses AI to generate intelligent fixes for detected linting errors (focusing only on changed lines)
5. **📝 Summary**: Generates detailed summaries of what was fixed and why
6. **🚀 PR Creation**: Creates a new pull request with fixes that can be merged into the original branch

## Security Considerations

### Required Permissions

The workflow requires these permissions:
```yaml
permissions:
  contents: write      # To create branches and update files
  pull-requests: write # To create fix PRs and add comments
```

### Fork Handling

The condition `if: github.event.pull_request.head.repo.full_name == github.repository` ensures that:
- ✅ Only runs on PRs from the same repository
- ❌ Prevents execution on PRs from forks
- 🛡️ Protects against security issues with external contributors

### Token Security

- The `GITHUB_TOKEN` is automatically provided by GitHub Actions
- Has limited permissions scoped only to the repository
- No additional secrets needed for basic functionality

## Advanced Configuration Examples

### Using Different AI Models

#### Ollama Models (Recommended)
```yaml
- name: Fix linting errors with Lintic (CodeLlama)
  uses: shindi-renuo/lintic@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    ollama-model: codellama:7b
    ollama-uri: http://localhost:11434/v1/
```

```yaml
- name: Fix linting errors with Lintic (DeepSeek Coder)
  uses: shindi-renuo/lintic@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    ollama-model: deepseek-coder:6.7b
```

#### OpenAI Models
```yaml
- name: Fix linting errors with Lintic (OpenAI)
  uses: shindi-renuo/lintic@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    ollama-model: gpt-4
    ollama-uri: https://api.openai.com/v1/
    openai-api-key: ${{ secrets.OPENAI_API_KEY }}
```

### Specific Ruby Version

```yaml
- name: Fix linting errors with Lintic
  uses: shindi-renuo/lintic@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    ruby-version: '3.2'
```

### Remote Ollama Instance

```yaml
- name: Fix linting errors with Lintic
  uses: shindi-renuo/lintic@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    ollama-uri: http://my-ollama-server:11434/v1/
```

## Troubleshooting

### Common Issues

| Issue | Symptoms | Solution |
|-------|----------|----------|
| **Permission Denied** | Action fails with 403 errors | Ensure repository settings allow GitHub Actions to create PRs |
| **Ollama Timeout** | Long setup times or timeouts | Model download takes time on first run - increase timeout |
| **Ruby Dependencies** | Gem installation failures | Check Ruby version compatibility |
| **Rate Limiting** | API errors with many requests | Implement delays between requests |
| **No Changes Applied** | Lintic runs but no PR created | Check if linting errors exist in changed files |

### Debug Mode

Enable verbose logging by adding environment variables:

```yaml
env:
  ACTIONS_STEP_DEBUG: true
  ACTIONS_RUNNER_DEBUG: true
```

### Workflow Logs Analysis

Check the Actions tab in your GitHub repository for:
- ✅ Successful file processing logs
- 🔍 RuboCop linting results
- 🤖 AI model responses
- 📝 PR creation confirmations

## Best Practices

### 🏆 Recommended Workflow

```yaml
name: Complete Ruby CI with Lintic

on:
  pull_request:
    paths:
      - '**/*.rb'
      - 'Gemfile*'
      - '.rubocop.yml'

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.1
          bundler-cache: true
      - name: Run tests
        run: bundle exec rspec
      - name: Run RuboCop (for reporting)
        run: bundle exec rubocop --format github

  lintic:
    runs-on: ubuntu-latest
    needs: test  # Only run if tests pass
    if: |
      github.event.pull_request.head.repo.full_name == github.repository &&
      !contains(github.event.pull_request.title, '[LINTIC]')
    steps:
      - uses: actions/checkout@v4
      - name: Fix linting errors
        uses: shindi-renuo/lintic@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          ollama-model: qwen2.5-coder:1.5b
```

### 💡 Pro Tips

1. **Test Locally First**: Run Lintic locally before enabling in CI
2. **Review Generated PRs**: Always review fix PRs before merging - AI isn't perfect
3. **Model Selection**:
   - `qwen2.5-coder:1.5b` - Fast, good for simple fixes
   - `codellama:7b` - Better understanding, slower
   - `gpt-4` - Best quality, requires OpenAI API key
4. **Exclude Lintic PRs**: Add condition to prevent Lintic from running on its own PRs
5. **Monitor Costs**: Track API usage if using OpenAI models

### 🎯 Integration Patterns

#### Sequential Processing
```yaml
jobs:
  test:
    # Run tests first
  lint:
    needs: test
    # Run linting after tests pass
  lintic:
    needs: lint
    # Fix linting issues if lint fails
```

#### Parallel Processing
```yaml
jobs:
  test:
    # Run tests
  lintic:
    # Run linting fixes in parallel
```

## Model Comparison

| Model | Speed | Quality | Resource Usage | Best For |
|-------|-------|---------|----------------|----------|
| `qwen2.5-coder:1.5b` | ⚡⚡⚡ | ⭐⭐⭐ | 🔋 Low | Quick fixes, high-frequency PRs |
| `codellama:7b` | ⚡⚡ | ⭐⭐⭐⭐ | 🔋🔋 Medium | Balanced quality/speed |
| `deepseek-coder:6.7b` | ⚡⚡ | ⭐⭐⭐⭐ | 🔋🔋 Medium | Complex refactoring |
| `gpt-4` | ⚡ | ⭐⭐⭐⭐⭐ | 💰 API Cost | Critical projects, best quality |

## FAQ

**Q: Will Lintic modify code that wasn't changed in my PR?**
A: No, Lintic focuses only on the lines that were actually changed in your PR (shown in the diff).

**Q: What happens if the AI makes a mistake?**
A: Lintic creates a separate PR with the fixes, so you can review and test before merging.

**Q: Can I use my own RuboCop configuration?**
A: Yes, Lintic respects your project's `.rubocop.yml` configuration file.

**Q: How long does it take to run?**
A: Typically 2-5 minutes, depending on the AI model and number of files to process.

**Q: Can I run this on private repositories?**
A: Yes, Lintic works with both public and private repositories.
