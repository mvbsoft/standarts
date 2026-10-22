# 1. One file per environment

Each environment has one file. The file names the environment. That short repeat is fine.

The deploy builds every image from the commit itself, so nothing uncommitted on the server
reaches it. A build that fails leaves the old version running, and the output names the step
that failed, so the next deploy can start from a clean state.
