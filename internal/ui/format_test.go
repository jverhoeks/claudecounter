package ui

import "testing"

func TestFormatUSD(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0, "$0.00"},
		{0.004, "$0.00"},
		{1.2, "$1.20"},
		{132.8, "$132.80"},
		{1234.5, "$1,234.50"},
		{1_234_567.89, "$1,234,567.89"},
	}
	for _, c := range cases {
		if got := FormatUSD(c.in); got != c.want {
			t.Errorf("FormatUSD(%v) = %q want %q", c.in, got, c.want)
		}
	}
}

func TestFormatTokShort(t *testing.T) {
	cases := []struct {
		in   uint64
		want string
	}{
		{0, "0"},
		{900, "900"},
		{1000, "1.0k"},
		{1234, "1.2k"},
		{999_500, "999.5k"},
		{1_000_000, "1.0M"},
		{2_340_000, "2.3M"},
	}
	for _, c := range cases {
		if got := FormatTokShort(c.in); got != c.want {
			t.Errorf("FormatTokShort(%v) = %q want %q", c.in, got, c.want)
		}
	}
}
