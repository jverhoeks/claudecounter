package insights

import (
	"testing"
	"time"
)

func TestDeliveryFinding(t *testing.T) {
	none := func(string, time.Time, time.Time) (int, bool) { return 0, true }
	some := func(string, time.Time, time.Time) (int, bool) { return 3, true }
	unknown := func(string, time.Time, time.Time) (int, bool) { return 0, false }
	z := time.Time{}

	if fs := deliveryFinding("/repo", z, z, false, 50, none, 10); len(fs) != 1 || fs[0].Category != CatDelivery {
		t.Errorf("expensive + no delivery should flag: %+v", fs)
	}
	if fs := deliveryFinding("/repo", z, z, false, 5, none, 10); len(fs) != 0 {
		t.Errorf("cheap session should not flag: %+v", fs)
	}
	if fs := deliveryFinding("/repo", z, z, false, 50, some, 10); len(fs) != 0 {
		t.Errorf("session with commits should not flag: %+v", fs)
	}
	if fs := deliveryFinding("/repo", z, z, false, 50, unknown, 10); len(fs) != 0 {
		t.Errorf("unknown delivery should not flag: %+v", fs)
	}
	if fs := deliveryFinding("/repo", z, z, true, 50, none, 10); len(fs) != 0 {
		t.Errorf("session with PR should not flag: %+v", fs)
	}
}

func TestApplyDelivery(t *testing.T) {
	none := func(string, time.Time, time.Time) (int, bool) { return 0, true }
	reports := []SessionReport{
		{ID: "a", Cwd: "/repo", USD: 50},                  // expensive, no delivery → flag
		{ID: "b", Cwd: "/repo", USD: 1},                   // cheap → skip
		{ID: "c", Cwd: "/repo", USD: 50, HasPRLink: true}, // has PR → skip
	}
	n := ApplyDelivery(reports, none, 10)
	if n != 1 {
		t.Fatalf("flagged = %d, want 1", n)
	}
	if len(reports[0].Findings) != 1 || reports[0].Findings[0].Category != CatDelivery {
		t.Errorf("report a not flagged: %+v", reports[0].Findings)
	}
	if len(reports[1].Findings) != 0 || len(reports[2].Findings) != 0 {
		t.Error("cheap/PR reports should be untouched")
	}
}
