{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.agents;
  skillDirs = [
    ".claude/skills"
    ".agents/skills"
    ".gemini/antigravity-cli/skills"
  ];
  own = lib.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../../agents/skills)
  );
  matt = path: {
    src = inputs.skills-mattpocock;
    inherit path;
  };
  upstream = {
    herdr = {
      src = inputs.skills-herdr;
      path = "skills/herdr";
    };
    ub-mode.src = inputs.skills-ub-mode;
    improve = {
      src = inputs.skills-improve;
      path = "skills/improve";
    };
    ce-optimize = {
      src = inputs.skills-compound-engineering;
      path = "skills/ce-optimize";
    };
    stop-slop.src = inputs.skills-stop-slop;
    humanizer.src = inputs.skills-humanizer;
    clonedeps = {
      src = inputs.skills-oh-my-opencode-slim;
      path = "src/skills/clonedeps";
    };
    security-audit = {
      src = inputs.skills-security-audit;
      path = "skills/security-audit";
    };
    gh-stack = {
      src = inputs.skills-gh-stack;
      path = "skills/gh-stack";
    };
    archify = {
      src = inputs.skills-archify;
      path = "archify";
    };
    impeccable = {
      src = inputs.skills-impeccable;
      path = ".agents/skills/impeccable";
      plugin = true;
    };
    avoid-ai-writing = {
      src = inputs.skills-avoid-ai-writing;
      path = "skills/avoid-ai-writing";
    };
    grill-for-unknowns = {
      src = inputs.skills-grill-for-unknowns;
      path = "plugins/grill-for-unknowns";
    };
    diagram-design = {
      src = inputs.skills-diagram-design;
      path = "skills/diagram-design";
      plugin = true;
    };
    codebase-design = matt "skills/engineering/codebase-design";
    diagnosing-bugs = matt "skills/engineering/diagnosing-bugs";
    domain-modeling = matt "skills/engineering/domain-modeling";
    grill-with-docs = matt "skills/engineering/grill-with-docs";
    implement-spec = matt "skills/engineering/implement-spec";
    improve-codebase-architecture = matt "skills/engineering/improve-codebase-architecture";
    research = matt "skills/engineering/research";
    standards-spec-review = matt "skills/engineering/code-review";
    to-spec = matt "skills/engineering/to-spec";
    to-tickets = matt "skills/engineering/to-tickets";
    grill-me = matt "skills/productivity/grill-me";
    grilling = matt "skills/productivity/grilling";
    handoff = matt "skills/productivity/handoff";
  };
  impeccableAgents = "${inputs.skills-impeccable}/.agents/skills/impeccable/agents";
  patched = map (lib.removeSuffix ".patch") (lib.attrNames (builtins.readDir ./patches));
  build =
    name: skill:
    pkgs.applyPatches {
      name = "skill-${name}";
      src = if skill ? path then "${skill.src}/${skill.path}" else skill.src;
      patches = lib.optional (lib.elem name patched) (./patches + "/${name}.patch");
    };
  built = lib.mapAttrs build upstream;
  dirsFor = skill: if skill.plugin or false then lib.remove ".claude/skills" skillDirs else skillDirs;
  links =
    dirs: source: name:
    map (dir: {
      name = "${dir}/${name}";
      value = {
        inherit source;
        force = true;
      };
    }) dirs;
  codexAgent = file: {
    name = ".codex/agents/${file}";
    value = {
      source = "${impeccableAgents}/${file}";
      force = true;
    };
  };
in
{
  options.oruc.agents.upstreamSkills = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "Every upstream skill with its patch applied; the skill links and the patches check in ci/patches.nix read it.";
  };

  config = {
    assertions = [
      {
        assertion = lib.subtractLists (lib.attrNames upstream) patched == [ ];
        message = "agent-skills: patches/ holds a patch for a skill that is not an upstream copy: ${toString (lib.subtractLists (lib.attrNames upstream) patched)}";
      }
      {
        assertion = lib.intersectLists own (lib.attrNames upstream) == [ ];
        message = "agent-skills: agents/skills and the upstream copies both hold ${toString (lib.intersectLists own (lib.attrNames upstream))}";
      }
    ];
    oruc.agents.upstreamSkills = pkgs.linkFarm "agent-skills" built;
    home.sessionVariables.ARCHIFY_UPDATE_CHECK_DISABLED = "1";
    home.packages = [ pkgs.nodejs_26 ];
    home.file = lib.listToAttrs (
      lib.concatMap (
        name:
        links skillDirs (config.lib.file.mkOutOfStoreSymlink "${cfg.checkout}/agents/skills/${name}") name
      ) own
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: skill: links (dirsFor skill) "${cfg.upstreamSkills}/${name}" name
        ) upstream
      )
      ++ map codexAgent (
        lib.filter (lib.hasSuffix ".toml") (lib.attrNames (builtins.readDir impeccableAgents))
      )
    );
  };
}
