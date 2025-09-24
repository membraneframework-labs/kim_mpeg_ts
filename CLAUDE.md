# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MPEG.TS is an Elixir library for parsing and manipulating MPEG Transport Stream (TS) files, developed by KIM Keep In Mind GmbH. It processes 188-byte MPEG-TS packets and provides stream demuxing/muxing capabilities used in production broadcast workflows.

**Key Details:**
- Language: Elixir (v1.18.3 with OTP 27)
- Current Version: 3.0.0 (major version)
- Package: `:mpeg_ts`
- License: Apache 2.0

## Development Commands

```bash
# Install dependencies
mix deps.get

# Compile project
mix compile

# Run tests
mix test

# Run tests with coverage
mix test --cover

# Generate documentation
mix docs

# Type checking with Dialyzer
mix dialyzer

# Code formatting
mix format
```

**Environment Setup:** Uses `mise` version manager (see `mise.toml`)

## Core Architecture

The library implements a **layered architecture** for MPEG-TS processing:

### 1. Low-Level Packet Processing
- **`MPEG.TS.Packet`**: Core 188-byte MPEG-TS packet parsing and generation
- **`MPEG.TS.Marshaler`** (Protocol): Serialization interface
- **`MPEG.TS.Unmarshaler`** (Behavior): Deserialization interface

### 2. Stream Tables and Metadata
- **`MPEG.TS.PAT`**: Program Association Table parsing
- **`MPEG.TS.PMT`**: Program Map Table parsing
- **`MPEG.TS.PSI`**: Program-Specific Information handling

### 3. Elementary Stream Processing
- **`MPEG.TS.PES`**: Packetized Elementary Stream handling
- **`MPEG.TS.PartialPES`**: Incomplete PES packet management
- **`MPEG.TS.StreamAggregator`**: Reassembles fragmented PES packets across multiple TS packets

### 4. High-Level Processing
- **`MPEG.TS.Demuxer`**: Main demultiplexing engine (stream-based processing)
- **`MPEG.TS.Muxer`**: MPEG-TS stream generation and muxing

## Data Flow

1. **Input**: Raw MPEG-TS binary stream (188-byte packets)
2. **Packet Layer**: Parse transport stream headers, extract PIDs and payloads
3. **Table Layer**: Parse PAT/PMT tables to identify elementary streams
4. **Stream Layer**: Aggregate packets by PID, reassemble PES packets
5. **Output**: Structured data (PAT, PMT, PES with timestamps and metadata)

## Key Design Patterns

- **Stream-Based Processing**: Uses Elixir Streams for efficient memory usage
- **Protocol-Based Marshaling**: Extensible serialization via protocols
- **Behavior-Based Unmarshaling**: Consistent deserialization interface
- **Stateful Processing**: Demuxer maintains state for stream aggregation and table tracking
- **Error Handling**: Dual mode - strict (raises exceptions) vs. lenient (logs warnings)

## Testing

**Framework**: ExUnit
- Tests mirror the `lib/` structure in `test/`
- **Test Data**: Binary TS files in `test/data/` (avsync.ts, broken.ts)
- **Test Helpers**: `test/support/factory.ex` provides binary test fixtures
- **Key Patterns**: Demuxing complete files vs. chunked processing, error handling in both modes

## Domain Knowledge

**MPEG Transport Stream Concepts:**
- **188-byte packets**: Fixed-size transport stream units
- **PID (Packet Identifier)**: Stream identification (13-bit)
- **PAT (Program Association Table)**: Maps programs to PMT PIDs
- **PMT (Program Map Table)**: Maps elementary streams to PIDs
- **PES (Packetized Elementary Stream)**: Audio/video payload format
- **PCR (Program Clock Reference)**: Timing synchronization

**Reference Documentation**: PDF specifications in `docs/` directory

## Development Context

- **Main Branch**: `main` (for PRs)
- **Current Branch**: `v3` (major version development)
- **Dependencies**: Minimal - only ExDoc and Dialyxir for development
- **Integration**: Part of Membrane Framework ecosystem