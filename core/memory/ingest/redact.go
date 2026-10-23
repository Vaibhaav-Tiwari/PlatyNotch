package ingest

import (
	"regexp"
	"sort"
	"strings"
)

const redacted = "[redacted]"

var (
	privateKey = regexp.MustCompile(`(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)`)
	jwt        = regexp.MustCompile(`eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`)
	skKey      = regexp.MustCompile(`sk-[A-Za-z0-9_-]{20,}`)
	awsKey     = regexp.MustCompile(`AKIA[0-9A-Z]{16}`)
	ghToken    = regexp.MustCompile(`gh[pousr]_[A-Za-z0-9]{36,}`)
	ghPAT      = regexp.MustCompile(`github_pat_[A-Za-z0-9_]{50,}`)
	slackToken = regexp.MustCompile(`xox[abprs]-[A-Za-z0-9-]{10,}`)
	googleKey  = regexp.MustCompile(`AIza[0-9A-Za-z_-]{35}`)
	// Digit groups separated by 1-2 of space, tab, NBSP, figure space, narrow
	// NBSP or dash (how card numbers are typed and rendered).
	cardRun = regexp.MustCompile(`[0-9](?:[ \t\x{00A0}\x{2007}\x{202F}-]{0,2}[0-9])*`)
)

// Redact replaces secrets with "[redacted]": private key blocks, JWTs,
// sk- API keys, AWS access key ids, GitHub tokens, Slack tokens, Google API
// keys and Luhn-valid 13-19 digit card numbers.
func Redact(s string) string {
	s = privateKey.ReplaceAllString(s, redacted)
	s = jwt.ReplaceAllString(s, redacted)
	s = skKey.ReplaceAllString(s, redacted)
	s = awsKey.ReplaceAllString(s, redacted)
	s = ghToken.ReplaceAllString(s, redacted)
	s = ghPAT.ReplaceAllString(s, redacted)
	s = slackToken.ReplaceAllString(s, redacted)
	s = googleKey.ReplaceAllString(s, redacted)
	return redactCards(s)
}

func isDigit(b byte) bool { return b >= '0' && b <= '9' }

type digitGroup struct{ start, end int }

type cardWin struct{ start, end int }

// redactCards finds Luhn-valid 13-19 digit card numbers. Within each maximal
// run of digit groups (cardRun separators) every window that starts
// and ends on a group boundary is a candidate; valid windows are merged.
func redactCards(s string) string {
	runs := cardRun.FindAllStringIndex(s, -1)
	var wins []cardWin
	for _, rl := range runs {
		var gs []digitGroup
		for k := rl[0]; k < rl[1]; {
			if !isDigit(s[k]) {
				k++
				continue
			}
			st := k
			for k < rl[1] && isDigit(s[k]) {
				k++
			}
			gs = append(gs, digitGroup{st, k})
		}
		for i := range gs {
			n := 0
			for j := i; j < len(gs); j++ {
				n += gs[j].end - gs[j].start
				if n > 19 {
					break
				}
				if n < 13 {
					continue
				}
				d := make([]int, 0, n)
				for k := gs[i].start; k < gs[j].end; k++ {
					if isDigit(s[k]) {
						d = append(d, int(s[k]-'0'))
					}
				}
				if luhn(d) {
					wins = append(wins, cardWin{gs[i].start, gs[j].end})
				}
			}
		}
	}
	if wins == nil {
		return s
	}
	// Redact the union of all valid windows: overlapping or adjacent windows
	// merge into one span, so a spurious earlier window cannot leave part of
	// the real card in the clear.
	sort.Slice(wins, func(a, b int) bool { return wins[a].start < wins[b].start })
	picked := []cardWin{wins[0]}
	for _, w := range wins[1:] {
		last := &picked[len(picked)-1]
		if w.start <= last.end+1 {
			if w.end > last.end {
				last.end = w.end
			}
		} else {
			picked = append(picked, w)
		}
	}
	var out strings.Builder
	last := 0
	for _, w := range picked {
		out.WriteString(s[last:w.start])
		out.WriteString(redacted)
		last = w.end
	}
	out.WriteString(s[last:])
	return out.String()
}

func luhn(d []int) bool {
	sum, alt := 0, false
	for i := len(d) - 1; i >= 0; i-- {
		n := d[i]
		if alt {
			if n *= 2; n > 9 {
				n -= 9
			}
		}
		sum += n
		alt = !alt
	}
	return sum%10 == 0
}
