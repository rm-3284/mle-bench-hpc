import argparse
import os
import sys
from pathlib import Path
from flask import Flask, jsonify, request
from mlebench.grade import validate_submission
from mlebench.registry import registry

app = Flask(__name__)

COMPETITION = None
REGISTRY = None

def run_validation(submission: Path) -> str:
    is_valid, message = validate_submission(submission, COMPETITION)
    return message


@app.route("/validate", methods=["POST"])
def validate():
    submission_file = request.files["file"]
    submission_path = Path("/tmp/submission_to_validate.csv")
    submission_file.save(submission_path)

    try:
        result = run_validation(submission_path)
    except Exception as e:
        return jsonify({"error": "An unexpected error occurred.", "details": str(e)}), 500

    return jsonify({"result": result})


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "running", "competition": COMPETITION.id if COMPETITION else None}), 200


def main():
    global COMPETITION, REGISTRY
    
    parser = argparse.ArgumentParser(description="Standalone grading server for HPC")
    parser.add_argument(
        "--competition-id",
        required=True,
        help="Competition ID to validate submissions for"
    )
    parser.add_argument(
        "--data-dir",
        required=True,
        help="Path to the mlebench data directory containing prepared competitions"
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Host to bind to (default: 127.0.0.1)"
    )
    parser.add_argument(
        "--port",
        type=int,
        default=5000,
        help="Port to listen on (default: 5000)"
    )
    args = parser.parse_args()
    
    REGISTRY = registry.set_data_dir(Path(args.data_dir))
    COMPETITION = REGISTRY.get_competition(args.competition_id)
    
    print(f"Starting grading server for competition: {args.competition_id}")
    print(f"Data directory: {args.data_dir}")
    print(f"Listening on: http://{args.host}:{args.port}")
    print(f"Validation endpoint: http://{args.host}:{args.port}/validate")
    print(f"Health endpoint: http://{args.host}:{args.port}/health")
    
    app.run(host=args.host, port=args.port)


if __name__ == "__main__":
    main()

