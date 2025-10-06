# Contributing to Rediacc Elite

Thank you for your interest in contributing to Rediacc Elite! This document provides guidelines and instructions for contributing.

## Code of Conduct

By participating in this project, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## How to Contribute

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include:

- Clear, descriptive title
- Detailed steps to reproduce
- Expected vs actual behavior
- Environment details (OS, versions, etc.)
- Any relevant logs or screenshots

### Suggesting Enhancements

Enhancement suggestions are welcome! Please provide:

- Clear description of the enhancement
- Use case and motivation
- Potential implementation approach (if applicable)

### Pull Request Process

1. **Fork and Clone**
   ```bash
   git clone https://github.com/YOUR-USERNAME/elite.git
   cd elite
   ```

2. **Create a Branch**
   ```bash
   git checkout -b feature/your-feature-name
   # or
   git checkout -b fix/your-bug-fix
   ```

3. **Make Your Changes**
   - Follow existing code style and conventions
   - Add tests if applicable
   - Update documentation as needed
   - Ensure all tests pass

4. **Commit Your Changes**
   ```bash
   git add .
   git commit -m "feat: add your feature description"
   ```

   Use conventional commit format:
   - `feat:` for new features
   - `fix:` for bug fixes
   - `docs:` for documentation changes
   - `chore:` for maintenance tasks
   - `refactor:` for code refactoring

5. **Push and Create PR**
   ```bash
   git push origin feature/your-feature-name
   ```

   Then create a pull request on GitHub with:
   - Clear title and description
   - Reference to related issues
   - Screenshots/examples if applicable

6. **Code Review**
   - Address review feedback promptly
   - Keep PR focused and reasonably sized
   - Maintain a professional, collaborative tone

### PR Requirements

- All PRs require at least 1 approval
- All CI checks must pass
- Branch must be up to date with main
- No merge conflicts

## Development Setup

Refer to the README for detailed setup instructions.

## Style Guidelines

- Use clear, descriptive variable and function names
- Comment complex logic
- Keep functions focused and reasonably sized
- Follow existing patterns in the codebase

## Testing

- Add tests for new features
- Ensure existing tests pass
- Run tests locally before pushing

## Questions?

If you have questions, feel free to:
- Open a discussion on GitHub
- Ask in pull request comments
- Check existing issues and documentation

Thank you for contributing!
