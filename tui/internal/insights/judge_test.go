package insights

import (
	"context"
	"testing"
)

func TestParseCLIResult(t *testing.T) {
	ok := []byte(`{"result":"hi there","total_cost_usd":0.1,"is_error":false}`)
	text, cost, err := parseCLIResult(ok)
	if err != nil || text != "hi there" || cost != 0.1 {
		t.Errorf("ok: %q %v %v", text, cost, err)
	}

	bad := []byte(`{"result":"","total_cost_usd":0.0,"is_error":true,"api_error_status":"overloaded"}`)
	if _, _, err := parseCLIResult(bad); err == nil {
		t.Error("expected error for is_error reply")
	}

	if _, _, err := parseCLIResult([]byte("not json")); err == nil {
		t.Error("expected parse error")
	}
}

func TestExtractJSON(t *testing.T) {
	cases := []struct {
		in   string
		want string
		ok   bool
	}{
		{`{"a":1}`, `{"a":1}`, true},
		{"```json\n{\"a\":1}\n```", `{"a":1}`, true},
		{`here is the result: {"a":{"b":2}} done`, `{"a":{"b":2}}`, true},
		{`a string with } brace then {"x":"has } inside"}`, `{"x":"has } inside"}`, true},
		{`no json here`, "", false},
	}
	for _, c := range cases {
		got, ok := extractJSON(c.in)
		if ok != c.ok || string(got) != c.want {
			t.Errorf("extractJSON(%q) = %q,%v want %q,%v", c.in, got, ok, c.want, c.ok)
		}
	}
}

// fakeJudge is the test double for the Judge interface.
type fakeJudge struct {
	reply string
	cost  float64
	err   error
}

func (f fakeJudge) Ask(ctx context.Context, prompt string) (string, float64, error) {
	return f.reply, f.cost, f.err
}
