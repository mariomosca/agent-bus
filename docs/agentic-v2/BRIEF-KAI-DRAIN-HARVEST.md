# BRIEF KAI — Agent-Team-OS v2.0: drain-on-Stop + harvest

**Da**: Alita (work-hub) · **A**: Kai · **Data**: 5 Jun 2026 · **Priorità**: normal
**⚠️ Stream più delicato dei tre**: tocca config condivisa tra i 2 account Claude di Mario.

## Contesto
Evoluzione Agent-Team-OS v2.0 (hive-GOD-agentic). Questo stream implementa due layer del protocollo: **drain-on-Stop** (layer 3) e **harvest/telemetry** (layer 4). Vedi `~/work-hub/plans/PLAN-AGENT-TEAM-OS.md` §v2.0 §3, §4, §5.

## ⚠️ REGOLA CRITICA: lavora sul REPO, non sul deployment
Il SORGENTE è QUESTO repo: `~/Projects/01-Building/agent-team-os/` (GitHub: mariomosca/agent-team-os).
Il deployment (`~/.claude/scripts`, `~/.claude/hooks`, ecc.) sono COPIE fatte da `install.sh`.
**NON editare mai `~/.claude/` direttamente** — diverge dal repo.
Vedi memoria `reference_agent-team-os-source.md` per il dettaglio.

Setup:
```bash
cd ~/Projects/01-Building/agent-team-os
git checkout -b feat/v2-drain-harvest
```

## Scope A — drain-on-Stop hook (layer 3)
1. Crea `hooks/agent-team-os-stop.sh` NEL REPO. Logica (vedi protocollo §4):
   - deriva agentId da cwd via AGENT_MAP.json (riusa funzioni di `scripts/agent-team-os-lib.sh`)
   - legge `~/.agent-team-os/agents/<id>/cursor.json` { lastProcessed }
   - fresh = messaggi inbox con id > lastProcessed
   - se fresh vuoto → exit 0 (permetti stop)
   - se fresh non vuoto → aggiorna cursor, output JSON `{ "decision": "block", "reason": "<lista messaggi>" }`
   - **LOOP GUARD obbligatorio**: cap N re-block consecutivi (default 3) per non intrappolare l'agente. Traccia il conteggio (es. in cursor.json o file temp).
2. Aggiungi le funzioni di supporto (`ab_drain_for_stop`, gestione cursor) in `scripts/agent-team-os-lib.sh`.
3. Aggiorna `install.sh` (cp del nuovo hook) + `hooks/hooks.json`.
4. **NON registrare il hook nei settings di Mario** né lanciare install.sh per attivarlo. Prepara il diff settings (snippet `hooks.Stop`) e lascialo ad Alita/Mario per approvazione via skill `update-config`. Un hook Stop rotto impatta TUTTE le sessioni su entrambi gli account.

## Scope B — harvest/telemetry (layer 4)
1. Crea uno script (`scripts/agent-team-os-harvest.sh` o `.mjs`, scegli tu) che:
   - per un dato cwd, risolve `~/.claude/projects/<cwd-slug>/` (slug = cwd senza `/` iniziale, `/`→`-`)
   - parsa i `.jsonl`, somma `message.usage.{input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens}` delle righe `type:"assistant"`
   - calcola costo USD con tabella per MODELLO (vedi protocollo §5: opus/sonnet/haiku). Modello da `message.model`, fallback sonnet.
   - output JSON: { inputTokens, outputTokens, cacheRead, cacheWrite, estimatedCostUsd, model breakdown }
2. Robustezza: salta righe/file malformati senza fallire.
3. Output deve poter alimentare la skill `claude-effort-tracker` (campo `parallel_streams`). Coordina il formato con Alita.

## Vincoli
- Bash POSIX-friendly + jq (già dipendenza di agent-team-os). Per l'harvest, .mjs/node è accettabile se più pulito sul parsing JSONL.
- NON attivare nulla nei settings live senza OK Mario.
- Testa il hook ISOLATO (es. invocandolo a mano con un cwd di test) prima di proporre l'attivazione.

## Workflow
- Plan mode → piano → `/reply` ad Alita per approvazione.
- Fine: `/reply <msg-id> response` con summary + artifact_refs + marker `===KAI_DRAIN_HARVEST_DONE===`.
- Ricorda: dopo merge, l'allineamento del deployment locale è `./install.sh` (ma l'attivazione hook resta gated da Mario).
