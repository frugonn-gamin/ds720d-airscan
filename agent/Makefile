# Agent de session universel (Apple Silicon + Intel).
CFLAGS += -O2 -Wall -Wextra -arch arm64 -arch x86_64 -mmacosx-version-min=11.0

ds720d-agent: ds720d-agent.c
	$(CC) $(CFLAGS) -o $@ $<
	codesign -s - -f -o runtime $@

clean:
	rm -f ds720d-agent
