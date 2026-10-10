SWIFTC = swiftc -O -swift-version 5
TOOLS = tonegen tapprobe musicrec calrec procstate eqmeasure preamplaw

atmoseq: main.swift
	$(SWIFTC) main.swift -o atmoseq

research: $(TOOLS:%=research/bin/%)

research/bin/%: research/%.swift
	@mkdir -p research/bin
	$(SWIFTC) $< -o $@

clean:
	rm -rf atmoseq research/bin

.PHONY: research clean
