SWIFTC = swiftc -O -swift-version 5
TOOLS = tonegen tapprobe musicrec calrec procstate eqmeasure preamplaw

atmoseq: main.swift
	$(SWIFTC) main.swift -o atmoseq

research: $(TOOLS:%=research/bin/%)

research/bin/%: research/%.swift
	@mkdir -p research/bin
	$(SWIFTC) $< -o $@

# Build AtmosEQ.app, install it in ~/Applications and start it at login.
install:
	packaging/install.sh

uninstall:
	packaging/uninstall.sh

clean:
	rm -rf atmoseq build research/bin

.PHONY: research install uninstall clean
