SHELL := /bin/bash

KOMOREBI_REPO ?= https://github.com/BeerEgg2001/Komorebi.git
# Only read when src/ does not exist yet; an existing src/ keeps its upstream-base.
KOMOREBI_REF  ?= 1.1.1
ARIB_FONT_SRC := fonts/WLCMARU2004ARIBU.TTF

SRC     := src
PATCHES := patches

ifeq ($(origin ANDROID_HOME),undefined)
ifneq ($(wildcard $(CURDIR)/.tmp/android-sdk),)
ANDROID_HOME := $(CURDIR)/.tmp/android-sdk
endif
endif

# Gradle variant: Debug or Release (Release is unsigned: upstream has no signingConfig).
VARIANT ?= Debug

GIT_ID := -c user.name="builder-komorebi" -c user.email="builder@localhost"

FONT_DIR     := $(SRC)/app/src/main/res/font
ASSET_FONTS  := $(SRC)/app/src/main/assets/fonts
NOTO_WEIGHTS := thin light regular medium semibold bold
ARIB_FONT    := $(ASSET_FONTS)/WLCMARU2004ARIBU.TTF

FFMPEG_SCRIPTS  := third_party/scripts
FFMPEG_EXCLUDES := /app/src/main/cpp/third_party/ffmpeg/ \
	$(foreach l,libavcodec libavfilter libavutil libswscale,/app/src/main/jniLibs/*/$(l).so)

.DEFAULT_GOAL := help
.PHONY: help prepare fonts ffmpeg build test update check clean

help:
	@echo 'Local patch-authoring / test-build workflow (not used by CI).'
	@echo
	@echo 'Targets:'
	@echo '  prepare   check out upstream $(KOMOREBI_REF) into $(SRC)/ (tag upstream-base, branch work),'
	@echo '            git-am $(PATCHES)/*.patch on top, then run "fonts" and "ffmpeg"'
	@echo '  fonts     copy NotoSansJP into res/font and copy the ARIB font into assets (idempotent)'
	@echo '  ffmpeg    cross-compile FFmpeg (arm64-v8a, armeabi-v7a) into third_party/prebuilt/ when'
	@echo '            missing or stale, then install its .so files into app/src/main/jniLibs and its'
	@echo '            headers into app/src/main/cpp/third_party/ffmpeg (idempotent)'
	@echo '  build     ./gradlew :app:assemble$$(VARIANT) in $(SRC)/ and list the APKs'
	@echo '  test      ./gradlew :app:testDebugUnitTest in $(SRC)/'
	@echo '  update    regenerate $(PATCHES)/ from the commits on top of upstream-base in $(SRC)/'
	@echo '  check     verify $(PATCHES)/ applies to pristine upstream (temp worktree; $(SRC)/ untouched)'
	@echo '  clean     remove $(SRC)/'
	@echo
	@echo 'Variables: KOMOREBI_REPO, KOMOREBI_REF (default $(KOMOREBI_REF)),'
	@echo '           VARIANT (default $(VARIANT); Debug|Release),'
	@echo '           ANDROID_HOME (default: environment, else .tmp/android-sdk if present),'
	@echo '           FFMPEG_BUILD_DIR (default .tmp/ffmpeg-build),'
	@echo '           FFMPEG_NDK (default: newest $$ANDROID_HOME/ndk/*, else a pinned r27c download)'
	@echo
	@echo 'Workflow: make prepare -> edit + git commit in $(SRC)/ -> make update -> make check'

prepare:
	@set -e; \
	if [ ! -e $(SRC)/.git ]; then \
		echo "Fetching upstream $(KOMOREBI_REF)"; \
		mkdir -p $(SRC); \
		git -C $(SRC) init -q; \
		git -C $(SRC) remote add origin $(KOMOREBI_REPO); \
		git -C $(SRC) fetch -q --depth 1 origin $(KOMOREBI_REF); \
		git -C $(SRC) checkout -q -b work FETCH_HEAD; \
		git -C $(SRC) submodule update --init --recursive --depth 1; \
		git -C $(SRC) tag upstream-base; \
	fi; \
	if ! git -C $(SRC) rev-parse -q --verify refs/tags/upstream-base >/dev/null; then \
		echo "$(SRC)/ has no upstream-base tag -- run 'make clean prepare'"; exit 1; \
	fi; \
	if [ "$$(git -C $(SRC) rev-parse HEAD)" != "$$(git -C $(SRC) rev-parse upstream-base^{commit})" ]; then \
		echo "$(SRC)/ is already past upstream-base; not re-applying patches."; \
		echo "Run 'make clean' first to start over (commit and 'make update' any work you want to keep)."; \
	elif ! ls $(PATCHES)/*.patch >/dev/null 2>&1; then \
		echo "No patches in $(PATCHES)/ -- nothing to apply."; \
	else \
		echo "Applying patches"; \
		git -C $(SRC) $(GIT_ID) am --committer-date-is-author-date $$(for p in $(PATCHES)/*.patch; do echo "$(CURDIR)/$$p"; done) \
			|| { echo "git am failed; resolve in $(SRC)/ or 'git -C $(SRC) am --abort'"; exit 1; }; \
	fi
	@$(MAKE) --no-print-directory fonts
	@$(MAKE) --no-print-directory ffmpeg

fonts:
	@test -d $(SRC)/app || { echo "No $(SRC)/ -- run 'make prepare' first"; exit 1; }
	@set -e; mkdir -p $(FONT_DIR); \
	excl=$$(git -C $(SRC) rev-parse --git-path info/exclude); \
	case "$$excl" in /*) ;; *) excl="$(SRC)/$$excl";; esac; \
	mkdir -p "$$(dirname "$$excl")"; \
	grep -qxF '/app/src/main/assets/fonts/WLCMARU2004ARIBU.TTF' "$$excl" 2>/dev/null \
		|| echo '/app/src/main/assets/fonts/WLCMARU2004ARIBU.TTF' >> "$$excl"; \
	for w in $(NOTO_WEIGHTS); do \
		f=notosansjp_$$w.ttf; \
		test -s $(FONT_DIR)/$$f || { echo "Copying $$f"; cp $(ASSET_FONTS)/$$f $(FONT_DIR)/$$f; }; \
	done; \
	cmp -s $(ARIB_FONT_SRC) $(ARIB_FONT) || { echo "Copying ARIB font"; cp $(ARIB_FONT_SRC) $(ARIB_FONT); }
	@$(FFMPEG_SCRIPTS)/patch-libaribcaption.sh $(SRC)/app

ffmpeg:
	@test -d $(SRC)/app || { echo "No $(SRC)/ -- run 'make prepare' first"; exit 1; }
	@set -ef; \
	excl=$$(git -C $(SRC) rev-parse --git-path info/exclude); \
	case "$$excl" in /*) ;; *) excl="$(SRC)/$$excl";; esac; \
	mkdir -p "$$(dirname "$$excl")"; \
	for p in $(FFMPEG_EXCLUDES); do \
		grep -qxF "$$p" "$$excl" 2>/dev/null || echo "$$p" >> "$$excl"; \
	done
	@$(if $(ANDROID_HOME),ANDROID_HOME="$(ANDROID_HOME)" )$(FFMPEG_SCRIPTS)/build.sh
	@$(FFMPEG_SCRIPTS)/install-app.sh $(SRC)/app

build:
	@test -x $(SRC)/gradlew || { echo "No $(SRC)/ -- run 'make prepare' first"; exit 1; }
	cd $(SRC) && $(if $(ANDROID_HOME),ANDROID_HOME="$(ANDROID_HOME)" )./gradlew :app:assemble$(VARIANT)
	@echo
	@echo 'APKs:'
	@ls -1 $(SRC)/app/build/outputs/apk/$(shell echo $(VARIANT) | tr A-Z a-z)/*.apk

test:
	@test -x $(SRC)/gradlew || { echo "No $(SRC)/ -- run 'make prepare' first"; exit 1; }
	cd $(SRC) && $(if $(ANDROID_HOME),ANDROID_HOME="$(ANDROID_HOME)" )./gradlew :app:testDebugUnitTest

# --zero-commit and --no-signature keep output byte-stable across rebases and git versions;
# -N drops "n/m" from subjects so adding a patch does not rewrite every file (order is the NNNN- prefix).
update:
	@set -e; \
	test -e $(SRC)/.git || { echo "No $(SRC)/ -- run 'make prepare' first"; exit 1; }; \
	git -C $(SRC) rev-parse -q --verify refs/tags/upstream-base >/dev/null \
		|| { echo "No upstream-base tag in $(SRC)/"; exit 1; }; \
	if [ -n "$$(git -C $(SRC) status --porcelain --untracked-files=normal --ignore-submodules=dirty)" ]; then \
		echo "$(SRC)/ has uncommitted changes -- commit or amend them first:"; \
		git -C $(SRC) status --short --ignore-submodules=dirty; exit 1; \
	fi; \
	mkdir -p $(PATCHES); \
	rm -f $(PATCHES)/*.patch; \
	git -C $(SRC) format-patch --no-signature --zero-commit --no-stat -N -o ../$(PATCHES) upstream-base..HEAD; \
	echo "Wrote $$(ls $(PATCHES)/*.patch 2>/dev/null | wc -l) patch(es) to $(PATCHES)/"

check:
	@set -e; \
	test -e $(SRC)/.git || { echo "No $(SRC)/ -- run 'make prepare' first"; exit 1; }; \
	ls $(PATCHES)/*.patch >/dev/null 2>&1 || { echo "No patches in $(PATCHES)/"; exit 1; }; \
	wt="$(CURDIR)/.tmp/check-worktree"; \
	mkdir -p .tmp; \
	git -C $(SRC) worktree remove --force "$$wt" 2>/dev/null || true; \
	rm -rf "$$wt"; \
	git -C $(SRC) worktree add -q --detach "$$wt" upstream-base; \
	trap 'git -C $(SRC) worktree remove --force "$$wt" >/dev/null 2>&1 || rm -rf "$$wt"; git -C $(SRC) worktree prune' EXIT; \
	if git -C "$$wt" $(GIT_ID) am $$(for p in $(PATCHES)/*.patch; do echo "$(CURDIR)/$$p"; done) >/dev/null; then \
		echo "OK: $$(ls $(PATCHES)/*.patch | wc -l) patch(es) apply cleanly to upstream-base"; \
	else \
		echo "FAIL: patch series does not apply to upstream-base"; \
		git -C "$$wt" am --show-current-patch=diff 2>&1 | head -20 || true; \
		git -C "$$wt" am --abort >/dev/null 2>&1 || true; exit 1; \
	fi

clean:
	rm -rf $(SRC)
