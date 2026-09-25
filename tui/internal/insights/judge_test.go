package insights

import (
	"context"
	"testing"
)

func TestParseCLIResult(t *testing.T) {
	ok := []byte(`{"result":"{\"a\":1}","structured_output":{"a":1},"total_cost_usd":0.1,"is_error":false}`)
	text, cost, err := parseCLIResult(ok)
	if err != nil || text != `{"a":1}` || cost != 0.1 {
		t.Errorf("ok: %q %v %v", text, cost, err)
	}

	// Text-only reply (schema not honoured) must be an error, not a silent "".
	if _, _, err := parseCLIResult([]byte(`{"result":"hi there","is_error":false}`)); err == nil {
		t.Error("expected error when structured_output is missing")
	}

	bad := []byte(`{"result":"","total_cost_usd":0.0,"is_error":true,"api_error_status":"overloaded"}`)
	if _, _, err := parseCLIResult(bad); err == nil {
		t.Error("expected error for is_error reply")
	}

	if _, _, err := parseCLIResult([]byte("not json")); err == nil {
		t.Error("expected parse error")
	}
}

// fakeJudge is the test double for the Judge interface.
type fakeJudge struct {
	reply string
	cost  float64
	err   error
}

func (f fakeJudge) Ask(ctx context.Context, prompt, schema string) (string, float64, error) {
	return f.reply, f.cost, f.err
}
