# Scores session states with the Laya classifier (convaiinnovations/laya).
# Run by LayaScorer via `uv run` with the snapshot directory as argv[1] (Go
# downloads and caches it); stdin {"questions": {...}, "states": [...]},
# stdout one Laya answers object per state. Uses the upstream reference code
# shipped in the model repo, so the model loads once per batch.
import json
import sys

import torch

req = json.load(sys.stdin)
d = sys.argv[1]
sys.path.insert(0, d)
from rl_agent_api import RLAgent  # noqa: E402  (lives in the snapshot)

try:
    from transformers.initialization import no_init_weights  # transformers 5
except ImportError:
    from transformers.modeling_utils import no_init_weights  # transformers 4

# Upstream builds the encoder with random weights, then overwrites them from
# the checkpoint (strict=True, so nothing is left uninitialised); skipping the
# random init cuts the load from ~45s to ~4s.
with no_init_weights():
    agent = RLAgent(d, device="mps" if torch.backends.mps.is_available() else "cpu")
json.dump([agent.system_one(s, req["questions"])["answers"] for s in req["states"]], sys.stdout)
