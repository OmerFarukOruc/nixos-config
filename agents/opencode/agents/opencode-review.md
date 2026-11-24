---
description: Read-only reviewer with no shell; it reads the worktree and writes only under /tmp/agents
mode: primary
model: mistral/zai-glm-5-3#max
permissions:
  - action: shell
    resource: "*"
    effect: deny
  - action: edit
    resource: "*"
    effect: deny
  - action: edit
    resource: /tmp/agents/**
    effect: allow
  - action: external_directory
    resource: "*"
    effect: deny
  - action: external_directory
    resource: /tmp/agents/**
    effect: allow
  - action: external_directory
    resource: ~/.claude/skills/**
    effect: allow
  - action: external_directory
    resource: ~/.claude/shared/**
    effect: allow
  - action: external_directory
    resource: ~/.claude/reference/**
    effect: allow
  - action: external_directory
    resource: ~/.agents/skills/**
    effect: allow
  - action: question
    resource: "*"
    effect: deny
  - action: subagent
    resource: "*"
    effect: deny
  - action: read
    resource: "*.env"
    effect: deny
  - action: read
    resource: "*.env.*"
    effect: deny
  - action: read
    resource: "*.env.example"
    effect: allow
---
