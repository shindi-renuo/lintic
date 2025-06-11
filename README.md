# Lintic

A medic for linting errors.

## Purpose

There have been countless times where I get far in a project, then commit and push, only to see that the branch CI fails, due to linting errors.

What if you didn't have to deal with this any more?

## How it works

If lintic discovers a linting error in your CI, it uses AI (configurable models) to find them and squash them, then open a PR so you can merge it into your feature branch.

## Getting Started

Follow these steps to set up and run Lintic.

### Prerequisites

*   **Ruby:** Ensure you have Ruby installed (version 3.0 or higher is recommended).
*   **Bundler:** Install Bundler (`gem install bundler`).
*   **Ollama:** Install Ollama and have it running. You can download it from [ollama.ai](https://ollama.ai/).
*   **CodeLlama Model:** Pull the `codellama` model using Ollama:
    ```bash
    ollama pull codellama
    ```

### Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/your-username/lintic.git # Replace with actual repo URL if different
    cd lintic
    ```
2.  **Install dependencies:**
    ```bash
    bundle install
    ```

### Configuration

Create a `.env` file in the root directory of the `lintic` project and add the following environment variables:

```dotenv
GITHUB_TOKEN="ghp_YOUR_ACTUAL_GITHUB_TOKEN"
GITHUB_REPO="owner/repository-name"
GITHUB_PR_NUMBER="123" # The number of the pull request you want to test
```

*   **`GITHUB_TOKEN`**: A GitHub Personal Access Token with `repo` scope (full control of private repositories) and potentially `workflow` scope if you plan to integrate with GitHub Actions. You can generate one from [GitHub Developer Settings](https://github.com/settings/tokens).
*   **`GITHUB_REPO`**: The full name of your GitHub repository in the format `owner/repository-name` (e.g., `renuo/my-project`).
*   **`GITHUB_PR_NUMBER`**: The numerical ID of the pull request you want Lintic to process.

### Usage

To run Lintic on a specific pull request, execute the `main.rb` script:

```bash
ruby main.rb
```

Lintic will:
1.  Fetch the files from the specified pull request.
2.  Identify Ruby files and run RuboCop to find linting errors.
3.  Use the configured AI model (CodeLlama via Ollama) to generate fixes for detected errors.
4.  Create a new branch and open a new pull request in your repository containing the proposed fixes. You can then review and merge this fix PR into your feature branch.

## CI Integration

Lintic can be easily integrated into your GitHub workflows to automatically fix linting errors on pull requests.

### Quick Setup

Add this to `.github/workflows/lintic.yml`:

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

For detailed setup instructions, configuration options, and troubleshooting, see [CI_SETUP.md](CI_SETUP.md).

### Example Repository

For a hands-on demonstration, refer to the `test/example_repo` directory. It contains a sample Ruby project with intentional linting errors and a `README.md` within that directory explaining how to use it for testing.
