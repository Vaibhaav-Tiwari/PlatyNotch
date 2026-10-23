package ingest

import (
	"regexp"
)

const redacted = "[redacted]"

var (
	privateKey = regexp.MustCompile(`(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)`)
	jwt        = regexp.MustCompile(`eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`)
	skKey      = regexp.MustCompile(`sk-[A-Za-z0-9_-]{20,}`)
	awsKey     = regexp.MustCompile(`AKIA[0-9A-Z]{16}`)
	cardRun    = regexp.MustCompile(`[0-9](?:[ -]?[0-9]){12,18}`)
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

func redactCards(s string) string {
	locs := cardRun.FindAllStringIndex(s, -1)
	if locs == nil {
		return s
	}
	out := make([]byte, 0, len(s))
	last := 0
	for _, l := range locs {
		a, b := l[0], l[1]
		// A longer digit run (or one glued to more digits) is not a card number.
		if (a > 0 && isDigit(s[a-1])) || (b < len(s) && isDigit(s[b])) {
			continue
		}
		digits := make([]int, 0, 19)
		for k := a; k < b; k++ {
			if isDigit(s[k]) {
				digits = append(digits, int(s[k]-'0'))
			}
		}
		if len(digits) < 13 || len(digits) > 19 || !luhn(digits) {
			continue
		}
		out = append(out, s[last:a]...)
		out = append(out, redacted...)
		last = b
	}
	out = append(out, s[last:]...)
	return string(out)
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
