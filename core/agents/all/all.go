// Package all blank-imports every agent adapter so each registers itself
// with the agents registry from its init().
package all

import (
	_ "github.com/platynotch/platynotch/core/agents/claudecode"
	_ "github.com/platynotch/platynotch/core/agents/codex"
	_ "github.com/platynotch/platynotch/core/agents/cursor"
	_ "github.com/platynotch/platynotch/core/agents/gemini"
	_ "github.com/platynotch/platynotch/core/agents/opencode"
	_ "github.com/platynotch/platynotch/core/agents/qwen"
)
