package insights

import "testing"

func TestContextWindow(t *testing.T) {
	cases := []struct {
		model string
		want  uint64
	}{
		{"claude-opus-4-8[1m]", 1_000_000},
		{"claude-sonnet-4-6[1m]", 1_000_000},
		{"claude-opus-4-8", 200_000},
		{"claude-sonnet-4-6", 200_000},
		{"claude-haiku-4-5", 200_000},
		{"", 200_000},
		{"something-unknown", 200_000},
	}
	for _, c := range cases {
		if got := ContextWindow(c.model); got != c.want {
			t.Errorf("ContextWindow(%q) = %d, want %d", c.model, got, c.want)
		}
	}
}
