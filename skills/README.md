# Agent skills

This directory holds agent skills for working on solomog. Each skill is a directory with a
`SKILL.md`: YAML frontmatter (`name`, `description`) followed by the instructions an agent loads
when the task matches the description.

| Skill | Use it for |
|---|---|
| [solomog-bundle](solomog-bundle/SKILL.md) | Creating, auditing, applying, and testing bundles under `bundles/` and `bundles/private/` |

Skills add task-specific detail on top of [AGENTS.md](../AGENTS.md). They don't replace it.

## Install a skill for Claude Code

Claude Code loads skills from `~/.claude/skills/<name>/` (every project) and from
`.claude/skills/<name>/` inside a project (that project only). Symlink rather than copy, so a
`git pull` updates the skill and there is one copy to edit.

To make the skill available in every Claude Code session, run this from the repo root:

```bash
mkdir -p ~/.claude/skills
ln -sfn "$PWD/skills/solomog-bundle" ~/.claude/skills/solomog-bundle
```

If you already have a copied `~/.claude/skills/solomog-bundle/` directory, remove it first. `ln`
won't replace a real directory, and it creates the link inside it instead.

To scope the skill to this repo only, link it into the project instead:

```bash
mkdir -p .claude/skills
ln -sfn ../../skills/solomog-bundle .claude/skills/solomog-bundle
```

Start a new Claude Code session, then confirm the skill appears in `/skills`. You can also invoke
it directly with `/solomog-bundle`.

## Install a skill for other clients

`SKILL.md` follows the open Agent Skills format, so a client that supports skills can load the
same directory. Point the client's skills location at `skills/<name>/`, or symlink it there. Check
the client's documentation for that location.

## Add a skill

1. Create `skills/<name>/SKILL.md`. The `name` in the frontmatter must match the directory name.
2. Write the `description` to say both what the skill does and when to load it. Agents choose a
   skill from its description alone.
3. Keep the skill generic. Customer names, ticket numbers, and customer configuration belong in
   `bundles/private/`, never in this public directory.
4. Add a row to the table above.
