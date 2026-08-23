# Gridlock game + player image. ONE image, two entrypoints:
#   /bin/gridlock         the game server (default)
#   /bin/gridlock-player  the thin register-and-listen player
#
# Both policy kinds live in the game server and are selected per seat by env
# on the PLAYER container (PLAYER_PROMPT vs PLAYER_SCRIPTED=<name>), which is
# why one image is enough.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

# nimby is pinned by version URL AND by sha256, the way
# Dockerfile.replay-viewer pins its own: a release asset that moves under a
# tag would otherwise rebuild this image with a compiler nobody reviewed.
RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    asset=nimby-Linux-X64; \
    sum=8e1e5c2769c657f599fb15dc4eef1bd861cdee898c6293d2a62df300c2f654c5; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    asset=nimby-Linux-ARM64; \
    sum=30959cf6c0826654b78c2d9180d390b2999ad3fc2d5d7e69b78028519ee48ca9; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  curl -fsSL -o /usr/local/bin/nimby \
    "https://github.com/treeform/nimby/releases/download/0.1.26/${asset}" && \
  echo "${sum}  /usr/local/bin/nimby" | sha256sum -c - && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/gridlock
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# A committed nim.cfg would pin the AUTHOR's package paths; regenerate it from
# this container's synced tree. Same recipe as ci.yml's test job, so a green
# test job means the image's compiler and package tree agree.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/gridlock-nimcache --out:gridlock src/gridlock.nim && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/gridlock-player-nimcache --out:gridlock-player \
    src/gridlock_player.nim

# Run image.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/gridlock
COPY --from=build /workspace/gridlock/gridlock /bin/gridlock
COPY --from=build /workspace/gridlock/gridlock-player /bin/gridlock-player
COPY --from=build /workspace/gridlock/data ./data
COPY --from=build /workspace/gridlock/client ./client
COPY --from=build /workspace/gridlock/replay-viewer ./replay-viewer
COPY --from=build /workspace/gridlock/*.json ./

CMD ["/bin/gridlock"]
