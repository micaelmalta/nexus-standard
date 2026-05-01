//! `nxs-inspect` — debug dump of .nxb structure
//!
//! Flag contract: context/data/2026-04-30-converter-suite-spec.yaml § nxs_inspect

use clap::Parser;
use nxs::convert::{self, CommonOpts, InspectArgs};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "nxs-inspect", about = "Inspect .nxb file structure")]
struct Cli {
    /// Emit structured JSON instead of the default pretty text
    #[arg(long)]
    json: bool,

    /// How many records to summarize (`all` = entire tail-index)
    #[arg(long, value_name = "N|all", default_value = "3")]
    records: String,

    /// Recompute DictHash and compare to preamble; exit 3 on mismatch
    #[arg(long)]
    verify_hash: bool,

    /// Input .nxb file
    input: String,
}

fn parse_records(s: &str) -> Option<usize> {
    if s == "all" {
        None
    } else {
        s.parse().ok()
    }
}

fn main() {
    let cli = Cli::parse();

    let input_path = if cli.input == "-" {
        None
    } else {
        Some(PathBuf::from(&cli.input))
    };

    let args = InspectArgs {
        common: CommonOpts {
            input_path,
            output_path: None,
        },
        json_output: cli.json,
        records_to_show: parse_records(&cli.records),
        verify_hash: cli.verify_hash,
    };

    let result = if args.json_output {
        nxs::convert::inspect::render_json(std::io::stdout(), &args)
    } else {
        nxs::convert::inspect::render_text(std::io::stdout(), &args)
    };

    match result {
        Ok(_report) => {}
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(convert::exit_code_for(&e));
        }
    }
}
