# Setting Up Lintic as a CI Step

This guide explains how to integrate Lintic into your GitHub workflow to automatically fix linting errors in pull requests.

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
        uses: your-org/lintic@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          ollama-model: qwen2.5-coder:1.5b
```

### Option 2: Manual Setup

If you prefer to set up everything manually:

```yaml
name: Lintic - Manual Setup

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

      - name: Install dependencies
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
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GITHUB_REPO: ${{ github.repository }}
          GITHUB_PR_NUMBER: ${{ github.event.pull_request.number }}
          OLLAMA_MODEL: qwen2.5-coder:1.5b
        run: |
          curl -o lintic.rb https://raw.githubusercontent.com/your-org/lintic/main/main.rb
          ruby lintic.rb
```

## Configuration Options

### Action Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `github-token` | GitHub token for API access | Yes | `${{ github.token }}` |
| `ollama-model` | AI model to use for fixing | No | `qwen2.5-coder:1.5b` |
| `ruby-version` | Ruby version to use | No | `3.1` |
| `skip-install` | Skip Ollama installation | No | `false` |

### Action Outputs

| Output | Description |
|--------|-------------|
| `fixes-applied` | Number of files that were fixed |
| `pr-created` | URL of the created fix PR (if any) |

### Environment Variables

- `GITHUB_TOKEN`: Authentication token (automatically provided in workflows)
- `GITHUB_REPO`: Repository name (automatically set)
- `GITHUB_PR_NUMBER`: Pull request number (automatically set)
- `OLLAMA_MODEL`: AI model to use (configurable)
- `OLLAMA_URI`: Ollama server URL (defaults to localhost)

## How It Works

1. **Trigger**: The workflow triggers when a PR is opened, updated, or reopened and contains Ruby files
2. **Setup**: Installs Ruby dependencies and Ollama with the specified AI model
3. **Analysis**: Runs RuboCop on changed Ruby files in the PR
4. **AI Fix**: Uses AI to generate fixes for any linting errors found
5. **PR Creation**: Creates a new PR with the fixes that can be merged into the original branch

## Security Considerations

### Permissions

The workflow requires these permissions:
- `contents: write` - To create branches and update files
- `pull-requests: write` - To create fix PRs and comment

### Fork Handling

The condition `if: github.event.pull_request.head.repo.full_name == github.repository` ensures that the action only runs on PRs from the same repository, not from forks. This prevents security issues with external contributors.

### Token Security

The `GITHUB_TOKEN` is automatically provided by GitHub Actions and has limited permissions scoped to the repository.

## Customization Examples

### Different AI Model

```yaml
- name: Fix linting errors with Lintic
  uses: your-org/lintic@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    ollama-model: codellama:7b
    ollama-uri: http;//localhost:11434/v1
```

### Specific Ruby Version

```yaml
- name: Fix linting errors with Lintic
  uses: your-org/lintic@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    ruby-version: 3.2
```

### Use Existing Ollama Instance

```yaml
- name: Fix linting errors with Lintic
  uses: your-org/lintic@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    skip-install: true
```

## Troubleshooting

### Common Issues

1. **Permission Denied**: Ensure your repository settings allow GitHub Actions to create PRs
2. **Ollama Timeout**: The setup might take a few minutes on first run while downloading the model
3. **Ruby Dependencies**: Make sure your repository has proper Ruby configuration

### Debug Mode

To enable more verbose logging, add this to your workflow:

```yaml
env:
  ACTIONS_STEP_DEBUG: true
```

### Workflow Logs

Check the Actions tab in your GitHub repository to see detailed logs of the Lintic execution.

## Best Practices

1. **Test First**: Test Lintic locally before enabling in CI
2. **Review Changes**: Always review the generated fix PRs before merging
3. **Model Selection**: Choose an appropriate AI model based on your needs (smaller models are faster but may be less accurate)
4. **Rate Limiting**: Be aware of GitHub API rate limits with high-frequency PRs

## Integration with Existing Workflows

You can combine Lintic with other CI steps:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: bundle exec rspec

  lintic:
    runs-on: ubuntu-latest
    needs: test  # Only run if tests pass
    if: github.event.pull_request.head.repo.full_name == github.repository
    steps:
      - uses: actions/checkout@v4
      - name: Fix linting errors
        uses: your-org/lintic@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```
