# Hermes setup project

Follow HERMES_ROADMAP.md. Work on ONE phase at a time and stop at the end of
each phase for me to test.

Rules:
- Never read, print or ask me for secrets. Create .env with placeholders and I fill them in.
- Never mount the Docker socket, use --privileged, host networking, or touch ~/.ssh
  or other projects' .env files and data folders.
- Before running any docker, sudo, rm or systemctl command, explain what it does and why.
- For multi-line files use heredocs (cat > file << 'EOF'), not nano.
- Config key names and model slugs in the roadmap may be outdated: check the
  current Hermes docs and openrouter.ai/models before writing config.
- After each phase write docs/phase-N.md: What is it / How does it work /
  What went wrong / How I tested it.
