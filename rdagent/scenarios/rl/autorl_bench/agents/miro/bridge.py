#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def build_task_question(
    task: str,
    base_model: str,
    description: str,
    instructions: str,
    workspace_listing: str,
) -> str:
    parts = [
        "You are helping with an AutoRL-Bench task.",
        f"Task name: {task}",
        f"Base model: {base_model}",
        "",
        "Task description:",
        description.strip(),
        "",
        "AutoRL-Bench instructions:",
        instructions.strip(),
        "",
        "Workspace contents:",
        workspace_listing.strip(),
        "",
        "Please reason carefully and provide the strongest possible solution.",
    ]
    return "\n".join(parts).strip()


def cmd_prepare_benchmark(args: argparse.Namespace) -> int:
    workspace = Path(args.workspace)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    description = (workspace / "description.md").read_text(encoding="utf-8")
    instructions = (workspace / "instructions.md").read_text(encoding="utf-8")
    workspace_listing = "\n".join(sorted(p.name for p in workspace.iterdir()))

    record = {
        "task_id": f"autorl_{args.task}",
        "task_question": build_task_question(
            task=args.task,
            base_model=args.base_model,
            description=description,
            instructions=instructions,
            workspace_listing=workspace_listing,
        ),
        "ground_truth": "",
        "metadata": {
            "source": "autorl-bench",
            "workspace": str(workspace),
            "base_model": args.base_model,
        },
    }

    metadata_path = output_dir / "standardized_data.jsonl"
    metadata_path.write_text(
        json.dumps(record, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(str(metadata_path))
    return 0


def find_latest_task_json(log_dir: Path) -> Path | None:
    task_files = sorted(log_dir.rglob("task_*.json"))
    if not task_files:
        return None
    return max(task_files, key=lambda p: p.stat().st_mtime)


def cmd_extract_result(args: argparse.Namespace) -> int:
    log_dir = Path(args.log_dir)
    output_file = Path(args.output_file)
    output_file.parent.mkdir(parents=True, exist_ok=True)

    latest = find_latest_task_json(log_dir)
    if latest is None:
        output_file.write_text(
            "# Miro Result\n\nNo task log was generated.\n",
            encoding="utf-8",
        )
        return 1

    data = json.loads(latest.read_text(encoding="utf-8"))

    summary = (
        data.get("output", {}).get("final_summary")
        or data.get("final_summary")
        or ""
    )
    boxed = (
        data.get("output", {}).get("final_boxed_answer")
        or data.get("model_boxed_answer")
        or ""
    )
    status = data.get("status", "unknown")

    lines = [
        "# Miro Result",
        "",
        f"- status: {status}",
        f"- log: {latest}",
        "",
    ]

    if boxed:
        lines.extend(["## Boxed Answer", "", boxed.strip(), ""])

    if summary:
        lines.extend(["## Summary", "", summary.strip(), ""])

    if not boxed and not summary:
        lines.extend(
            [
                "## Raw Keys",
                "",
                "No final answer fields were found. Available top-level keys:",
                "",
                ", ".join(sorted(data.keys())),
                "",
            ]
        )

    output_file.write_text("\n".join(lines), encoding="utf-8")
    return 0


def cmd_write_proxy_config(args: argparse.Namespace) -> int:
    output_file = Path(args.output_file)
    output_file.parent.mkdir(parents=True, exist_ok=True)

    driver_alias = args.driver_alias
    upstream_model = args.upstream_model
    judge_upstream_model = args.judge_upstream_model
    upstream_api_base = args.upstream_api_base
    upstream_api_key = args.upstream_api_key

    lines = ["model_list:"]
    lines.extend(
        [
            f"  - model_name: {driver_alias}",
            "    litellm_params:",
            f"      model: {upstream_model}",
            f"      api_base: {upstream_api_base}",
            f"      api_key: {upstream_api_key}",
        ]
    )
    for alias in ["gpt-4.1", "gpt-4.1-2025-04-14", "o3-mini-2025-01-31"]:
        lines.extend(
            [
                f"  - model_name: {alias}",
                "    litellm_params:",
                f"      model: {judge_upstream_model}",
                f"      api_base: {upstream_api_base}",
                f"      api_key: {upstream_api_key}",
            ]
        )
    lines.extend(
        [
            "litellm_settings:",
            "  drop_params: true",
        ]
    )

    output_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(str(output_file))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Miro bridge utilities")
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare-benchmark")
    prepare.add_argument("--workspace", required=True)
    prepare.add_argument("--output-dir", required=True)
    prepare.add_argument("--task", required=True)
    prepare.add_argument("--base-model", required=True)
    prepare.set_defaults(func=cmd_prepare_benchmark)

    extract = subparsers.add_parser("extract-result")
    extract.add_argument("--log-dir", required=True)
    extract.add_argument("--output-file", required=True)
    extract.set_defaults(func=cmd_extract_result)

    proxy = subparsers.add_parser("write-proxy-config")
    proxy.add_argument("--output-file", required=True)
    proxy.add_argument("--driver-alias", required=True)
    proxy.add_argument("--upstream-model", required=True)
    proxy.add_argument("--judge-upstream-model", required=True)
    proxy.add_argument("--upstream-api-base", required=True)
    proxy.add_argument("--upstream-api-key", required=True)
    proxy.set_defaults(func=cmd_write_proxy_config)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
