package hookjson

import (
	"os"
	"strings"
	"testing"
)

const topDoc = `{"zeta":1,"model":"opus","statusLine":{"type":"command","command":"x"},"alpha":[1,2]}`

func TestSetTopLevelPreservesOrderBackupAndMode(t *testing.T) {
	p := writeTemp(t, "settings.json", []byte(topDoc))
	if err := os.Chmod(p, 0o640); err != nil {
		t.Fatal(err)
	}
	changed, err := SetTopLevel(p, "statusLine", []byte(`{"type":"command","command":"y"}`))
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	b, _ := os.ReadFile(p)
	s := string(b)
	if !(strings.Index(s, `"zeta"`) < strings.Index(s, `"model"`) &&
		strings.Index(s, `"model"`) < strings.Index(s, `"statusLine"`) &&
		strings.Index(s, `"statusLine"`) < strings.Index(s, `"alpha"`)) {
		t.Fatalf("order lost:\n%s", s)
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o640 {
		t.Fatalf("mode %v", st.Mode())
	}
	bak, err := os.ReadFile(p + ".platynotch-backup")
	if err != nil || string(bak) != topDoc {
		t.Fatalf("backup %q %v", bak, err)
	}
	// Second change keeps the original backup.
	if _, err := SetTopLevel(p, "statusLine", nil); err != nil {
		t.Fatal(err)
	}
	bak, _ = os.ReadFile(p + ".platynotch-backup")
	if string(bak) != topDoc {
		t.Fatalf("backup overwritten: %s", bak)
	}
}

func TestGetAndDeleteTopLevel(t *testing.T) {
	p := writeTemp(t, "settings.json", []byte(topDoc))
	raw, ok, err := GetTopLevel(p, "model")
	if err != nil || !ok || string(raw) != `"opus"` {
		t.Fatalf("%s %v %v", raw, ok, err)
	}
	if _, ok, _ := GetTopLevel(p, "nope"); ok {
		t.Fatal("unexpected key")
	}
	if changed, err := SetTopLevel(p, "statusLine", nil); err != nil || !changed {
		t.Fatalf("%v %v", changed, err)
	}
	if _, ok, _ := GetTopLevel(p, "statusLine"); ok {
		t.Fatal("not deleted")
	}
	if changed, _ := SetTopLevel(p, "statusLine", nil); changed {
		t.Fatal("second delete should be a no-op")
	}
}

func TestTopLevelMissingFileAndInvalid(t *testing.T) {
	missing := t.TempDir() + "/sub/settings.json"
	if _, ok, err := GetTopLevel(missing, "k"); ok || err != nil {
		t.Fatalf("%v %v", ok, err)
	}
	if changed, err := SetTopLevel(missing, "k", nil); changed || err != nil {
		t.Fatalf("%v %v", changed, err)
	}
	if changed, err := SetTopLevel(missing, "k", []byte(`1`)); !changed || err != nil {
		t.Fatalf("%v %v", changed, err)
	}
	bad := writeTemp(t, "bad.json", []byte(`{nope`))
	if _, err := SetTopLevel(bad, "k", []byte(`1`)); err == nil {
		t.Fatal("expected error")
	}
	if b, _ := os.ReadFile(bad); string(b) != `{nope` {
		t.Fatal("invalid file modified")
	}
}

func TestStatuslineCommandAndIsOurs(t *testing.T) {
	c := StatuslineCommand(testBin)
	if c != `"`+testBin+`" statusline` {
		t.Fatal(c)
	}
	for cmd, want := range map[string]bool{
		c:                                  true,
		`/usr/local/bin/notch statusline`:  true,
		`"/x/notch-pro" statusline`:        true,
		`"/x/notch" hook claude-code stop`: false,
		`~/.claude/mystatus.sh`:            false,
		`"/x/other" statusline`:            false,
	} {
		if IsOursStatusline(cmd) != want {
			t.Errorf("IsOursStatusline(%q) != %v", cmd, want)
		}
	}
}

const nestedDoc = `{"globalShortcut":"x","mcpServers":{"other":{"command":"o","args":[]},"zz":{"command":"z"}},"tail":true}`

func TestSetNestedKeepsSiblingsOrderAndBackup(t *testing.T) {
	p := writeTemp(t, "cfg.json", []byte(nestedDoc))
	changed, err := SetNested(p, "mcpServers", "platynotch", []byte(`{"command":"/b","args":["mcp"]}`))
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	b, _ := os.ReadFile(p)
	s := string(b)
	order := []string{`"globalShortcut"`, `"mcpServers"`, `"other"`, `"zz"`, `"platynotch"`, `"tail"`}
	for i := 1; i < len(order); i++ {
		if strings.Index(s, order[i-1]) >= strings.Index(s, order[i]) {
			t.Fatalf("order lost at %s:\n%s", order[i], s)
		}
	}
	raw, ok, err := GetNested(p, "mcpServers", "platynotch")
	if err != nil || !ok || canon(t, raw) != canon(t, []byte(`{"command":"/b","args":["mcp"]}`)) {
		t.Fatalf("%s %v %v", raw, ok, err)
	}
	if bak, _ := os.ReadFile(p + ".platynotch-backup"); string(bak) != nestedDoc {
		t.Fatalf("backup %q", bak)
	}
	if changed, _ := SetNested(p, "mcpServers", "platynotch", []byte(`{"command":"/b","args":["mcp"]}`)); changed {
		t.Fatal("same value should be a no-op")
	}
	if changed, err := SetNested(p, "mcpServers", "platynotch", nil); err != nil || !changed {
		t.Fatalf("delete: %v %v", changed, err)
	}
	if _, ok, _ := GetNested(p, "mcpServers", "platynotch"); ok {
		t.Fatal("not deleted")
	}
	if _, ok, _ := GetNested(p, "mcpServers", "other"); !ok {
		t.Fatal("sibling lost")
	}
}

func TestSetNestedCreatesAndRejectsNonObject(t *testing.T) {
	p := t.TempDir() + "/sub/mcp.json"
	if changed, err := SetNested(p, "mcpServers", "k", nil); changed || err != nil {
		t.Fatalf("%v %v", changed, err)
	}
	if changed, err := SetNested(p, "mcpServers", "k", []byte(`1`)); !changed || err != nil {
		t.Fatalf("%v %v", changed, err)
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	bad := writeTemp(t, "bad.json", []byte(`{"mcpServers":[1]}`))
	if _, err := SetNested(bad, "mcpServers", "k", []byte(`1`)); err == nil {
		t.Fatal("expected error for non-object parent")
	}
	if b, _ := os.ReadFile(bad); string(b) != `{"mcpServers":[1]}` {
		t.Fatal("file modified")
	}
}
