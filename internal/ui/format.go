package ui

import (
	"fmt"
	"strings"
)

// FormatUSD renders a dollar value like "$1,234.56".
func FormatUSD(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	whole := int64(v)
	cents := int64((v-float64(whole))*100 + 0.5)
	if cents == 100 {
		whole++
		cents = 0
	}
	s := fmt.Sprintf("%d", whole)
	var b strings.Builder
	n := len(s)
	for i, r := range s {
		if i > 0 && (n-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}
	sign := ""
	if neg {
		sign = "-"
	}
	return fmt.Sprintf("%s$%s.%02d", sign, b.String(), cents)
}

// FormatTokShort renders token counts as "900", "1.2k", "2.3M".
func FormatTokShort(n uint64) string {
	switch {
	case n < 1000:
		return fmt.Sprintf("%d", n)
	case n < 1_000_000:
		return fmt.Sprintf("%.1fk", float64(n)/1000.0)
	default:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000.0)
	}
}
