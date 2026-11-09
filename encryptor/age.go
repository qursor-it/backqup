package encryptor

import (
	"fmt"
	"strings"

	"github.com/gobackup/gobackup/helper"
)

// Age encryptor, uses the `age` CLI (https://age-encryption.org) with public keys only,
// so the host running the backups never holds a secret able to decrypt them.
//
// - recipients: list (or single string) of age1... public keys
// - recipients_file: path of a file with one recipient per line
type Age struct {
	Base
	recipients     []string
	recipientsFile string
	encryptPath    string
}

func NewAge(base *Base) *Age {
	return &Age{
		Base:           *base,
		recipients:     base.viper.GetStringSlice("recipients"),
		recipientsFile: base.viper.GetString("recipients_file"),
		encryptPath:    base.archivePath + ".age",
	}
}

func (enc *Age) perform() (encryptPath string, err error) {
	if len(enc.recipients) == 0 && len(enc.recipientsFile) == 0 {
		err = fmt.Errorf("age: at least one of `recipients` or `recipients_file` is required")
		return
	}

	opts := enc.options()
	opts = append(opts, "-o", enc.encryptPath, enc.archivePath)
	_, err = helper.Exec("age", opts...)
	if err != nil {
		err = fmt.Errorf("age encrypt failed: %s `age %s`", strings.TrimSpace(err.Error()), strings.Join(opts, " "))
		return "", err
	}
	return enc.encryptPath, nil
}

func (enc *Age) options() (opts []string) {
	for _, r := range enc.recipients {
		opts = append(opts, "-r", r)
	}
	if len(enc.recipientsFile) > 0 {
		opts = append(opts, "-R", enc.recipientsFile)
	}
	return opts
}
