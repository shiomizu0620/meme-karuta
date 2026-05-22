CC      = gcc
CFLAGS  = -Wall -Wextra -O2 -std=c99
TARGET  = serializer
SRC     = serializer.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC) serializer.h
	$(CC) $(CFLAGS) -o $@ $(SRC)

clean:
	rm -f $(TARGET)
