package encryptor

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gobackup/gobackup/config"
	"github.com/longbridgeapp/assert"
	"github.com/spf13/viper"
)

func TestAge_options(t *testing.T) {
	base := &Base{viper: viper.New(), archivePath: "/foo/bar"}

	enc := NewAge(base)
	assert.Equal(t, "/foo/bar.age", enc.encryptPath)
	assert.Equal(t, 0, len(enc.options()))

	base.viper.Set("recipients", []string{"age1aaa", "age1bbb"})
	base.viper.Set("recipients_file", "/keys/r.txt")
	enc = NewAge(base)
	assert.Equal(t, "-r age1aaa -r age1bbb -R /keys/r.txt", strings.Join(enc.options(), " "))

	// a single string is accepted too
	base.viper.Set("recipients", "age1ccc")
	base.viper.Set("recipients_file", "")
	enc = NewAge(base)
	assert.Equal(t, "-r age1ccc", strings.Join(enc.options(), " "))
}

func TestAge_missingRecipient(t *testing.T) {
	enc := NewAge(&Base{viper: viper.New(), archivePath: "/foo/bar"})
	_, err := enc.perform()
	assert.NotNil(t, err)
	assert.True(t, strings.Contains(err.Error(), "recipients"))
}

func TestAge_roundTrip(t *testing.T) {
	for _, bin := range []string{"age", "age-keygen"} {
		if _, err := exec.LookPath(bin); err != nil {
			t.Skipf("%s not in PATH", bin)
		}
	}

	dir := t.TempDir()
	keyFile := filepath.Join(dir, "key.txt")
	out, err := exec.Command("age-keygen", "-o", keyFile).CombinedOutput()
	assert.NoError(t, err)
	// age-keygen prints "Public key: age1..." on stderr
	pub := strings.TrimSpace(string(out)[strings.Index(string(out), "age1"):])

	plain := filepath.Join(dir, "backup.tar")
	assert.NoError(t, os.WriteFile(plain, []byte("secret backup content"), 0o600))

	v := viper.New()
	v.Set("recipients", []string{pub})
	model := config.ModelConfig{
		Viper:       viper.New(),
		EncryptWith: config.SubConfig{Type: "age", Viper: v},
	}
	model.Viper.Set("Ext", ".tar")

	encPath, err := Run(plain, model)
	assert.NoError(t, err)
	assert.Equal(t, plain+".age", encPath)
	assert.Equal(t, ".tar.age", model.Viper.GetString("Ext"))

	enc, _ := os.ReadFile(encPath)
	assert.False(t, strings.Contains(string(enc), "secret backup content"))

	dec, err := exec.Command("age", "-d", "-i", keyFile, encPath).Output()
	assert.NoError(t, err)
	assert.Equal(t, "secret backup content", string(dec))
}
