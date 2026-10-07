package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/ecosyste-ms/parser/internal/parser"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, output, errors io.Writer) error {
	flags := flag.NewFlagSet("manifest-parser", flag.ContinueOnError)
	flags.SetOutput(errors)
	identify := flags.Bool("identify", false, "identify a manifest filename without reading it")
	strip := flags.Int("strip-components", 0, "remove leading archive path components")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 || *strip < 0 {
		return fmt.Errorf("usage: manifest-parser [-identify] [-strip-components N] path")
	}
	if *identify {
		return json.NewEncoder(output).Encode(map[string]bool{"supported": parser.Identify(flags.Arg(0))})
	}
	report, err := parser.Parse(flags.Arg(0), *strip)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(report)
}
