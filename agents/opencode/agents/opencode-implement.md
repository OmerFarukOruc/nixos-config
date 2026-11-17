---
description: Implementer with every tool except the question form, guarded like a Claude agent that skips permissions by its brief
mode: primary
model: mistral/zai-glm-5-3#max
permissions:
  - action: question
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
