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
	cardRun    = regexp.MustCompile(`[0-9](?:[ -]?[0-9])*`)
)

// Redact replaces secrets with "[redacted]": private key blocks, JWTs,
// sk- API keys, AWS access key ids and Luhn-valid 13-19 digit card numbers.
func Redact(s string) string {
	s = privateKey.ReplaceAllString(s, redacted)
	s = jwt.ReplaceAllString(s, redacted)
	s = skKey.ReplaceAllString(s, redacted)
	s = awsKey.ReplaceAllString(s, redacted)
	return redactCards(s)
}

func isDigit(b byte) bool { return b >= '0' && b <= '9' }

type digitGroup struct{ start, end int }

type cardWin struct {
	start, end, digits int
	cardLike           bool // grouped like a printed card, preferred on ties
}

// redactCards finds Luhn-valid 13-19 digit card numbers. Within each maximal
// run of digit groups (single space/dash separators) every window that starts
// and ends on a group boundary is a candidate; longest windows win and
// redacted windows never overlap.
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
					wins = append(wins, cardWin{gs[i].start, gs[j].end, n, cardLike(gs[i : j+1])})
				}
			}
		}
	}
	if wins == nil {
		return s
	}
	sort.Slice(wins, func(a, b int) bool {
		if wins[a].cardLike != wins[b].cardLike {
			return wins[a].cardLike
		}
		if wins[a].digits != wins[b].digits {
			return wins[a].digits > wins[b].digits
		}
		return wins[a].start < wins[b].start
	})
	var picked []cardWin
	for _, w := range wins {
		ok := true
		for _, p := range picked {
			if w.start < p.end && p.start < w.end {
				ok = false
				break
			}
		}
		if ok {
			picked = append(picked, w)
		}
	}
	sort.Slice(picked, func(a, b int) bool { return picked[a].start < picked[b].start })
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

// cardLike reports a single group, or 4-digit groups ending in a group of up
// to 4 digits, or the Amex 4-6-5 layout.
func cardLike(gs []digitGroup) bool {
	size := func(g digitGroup) int { return g.end - g.start }
	if len(gs) == 1 {
		return true
	}
	if len(gs) == 3 && size(gs[0]) == 4 && size(gs[1]) == 6 && size(gs[2]) == 5 {
		return true
	}
	for _, g := range gs[:len(gs)-1] {
		if size(g) != 4 {
			return false
		}
	}
	return size(gs[len(gs)-1]) <= 4
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
