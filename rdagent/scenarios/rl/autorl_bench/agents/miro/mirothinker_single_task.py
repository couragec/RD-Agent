#!/usr/bin/env python3
import argparse
import asyncio
import json
import sys
from pathlib import Path

from hydra import compose, initialize_config_dir


def build_config(args: argparse.Namespace):
    conf_dir = Path(args.app_dir) / "conf"
    overrides = [
        "llm=qwen-3",
        f"llm.provider={args.llm_provider}",
        f"llm.model_name={args.llm_model}",
        f"llm.base_url={args.llm_base_url}",
        f"llm.api_key={args.llm_api_key}",
        f"llm.max_tokens={args.llm_max_tokens}",
        "llm.async_client=true",
        "agent=single_agent_keep5",
        "agent.main_agent.tools=[]",
        "agent.main_agent.max_turns=20",
        "agent.keep_tool_result=0",
        "agent.context_compress_limit=0",
        f"debug_dir={args.log_dir}",
    ]

    with initialize_config_dir(config_dir=str(conf_dir), version_base=None):
        return compose(config_name="config", overrides=overrides)


async def run_task(args: argparse.Namespace) -> dict:
    app_dir = Path(args.app_dir)
    sys.path.insert(0, str(app_dir))

    from src.core.pipeline import create_pipeline_components, execute_task_pipeline

    cfg = build_config(args)

    main_agent_tool_manager, sub_agent_tool_managers, output_formatter = (
        create_pipeline_components(cfg)
    )

    final_summary, final_boxed_answer, log_file_path, _ = await execute_task_pipeline(
        cfg=cfg,
        task_id=args.task_id,
        task_file_name="",
        task_description=args.task_description,
        main_agent_tool_manager=main_agent_tool_manager,
        sub_agent_tool_managers=sub_agent_tool_managers,
        output_formatter=output_formatter,
        log_dir=args.log_dir,
    )

    return {
        "final_summary": final_summary,
        "final_boxed_answer": final_boxed_answer,
        "log_file_path": log_file_path,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a single MiroThinker task")
    parser.add_argument("--app-dir", required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--task-description", required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--output-file", required=True)
    parser.add_argument("--llm-provider", default="openai")
    parser.add_argument("--llm-model", required=True)
    parser.add_argument("--llm-base-url", required=True)
    parser.add_argument("--llm-api-key", required=True)
    parser.add_argument("--llm-max-tokens", type=int, default=1024)
    args = parser.parse_args()

    Path(args.log_dir).mkdir(parents=True, exist_ok=True)
    result = asyncio.run(run_task(args))
    Path(args.output_file).write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
