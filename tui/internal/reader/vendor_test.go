package reader

import "testing"

// A configured Grok root need not be named "sessions" — sources.Load
// places no such requirement on a custom root. Before projectUnderRoot,
// grokParser anchored on a literal "/sessions/" substring, so a root
// like this would silently return "" from Project and false from
// IsSubagent for every event: a project's spend vanishing into the
// empty-key bucket, and a subagent turn misfiled as main-session spend.
func TestGrokParser_ProjectAndSubagent_RootWithoutSessionsSegment(t *testing.T) {
	root := "/Users/me/my-grok-archive"
	main := root + "/%2FUsers%2Fme%2Fsrc%2Fproj/01a0-sess/updates.jsonl"
	sub := root + "/%2FUsers%2Fme%2F.grok%2Fworktrees%2Fx%2Fsubagent-01a0/01a0/updates.jsonl"

	p := grokParser{}
	if got := p.Project(root, main); got != "-Users-me-src-proj" {
		t.Fatalf("project = %q, want -Users-me-src-proj", got)
	}
	if p.IsSubagent(root, main) {
		t.Fatal("a main session must not be flagged")
	}
	if !p.IsSubagent(root, sub) {
		t.Fatal("a subagent worktree session must be flagged")
	}
}

// The same risk applies to Claude: Phase A shipped configurable Claude
// roots, and claudeParser.Project must not depend on the root being
// named "projects".
func TestClaudeParser_Project_RootWithoutProjectsSegment(t *testing.T) {
	root := "/Users/me/my-claude-archive"
	path := root + "/-foo-bar/abc.jsonl"

	p := claudeParser{}
	if got := p.Project(root, path); got != "-foo-bar" {
		t.Fatalf("project = %q, want -foo-bar", got)
	}
}
