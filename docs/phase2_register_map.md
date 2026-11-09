# Phase 2a — AXI4-Lite ECC controller: architecture and register map

**Status:** specification. No RTL written yet.

This document is deliberately committed *before* any Phase 2 RTL. Every
decision below is a decision that would otherwise get buried inside the code,
and a register map is a contract: once software is written against it, changing
it is expensive. Settling it first is how real IP is developed, and it means
each later Phase 2 increment is small and reviewable.

---

## 1. What Phase 2 turns Phase 1 into

Phase 1 produced two combinational functions: a 64-bit-in / 72-bit-out encoder
and a 72-bit-in / 64-bit-out decoder. Useful, but not yet an IP block — nothing
stores the codewords, nothing counts errors, nothing tells software that a
fault occurred.

Phase 2 wraps them into a **protected memory with a bus interface**:

```
                 +---------------------------------------------------+
                 |  ecc_axil_ctrl                                    |
  AXI4-Lite      |                                                   |
  ===========>   |  +-----------+    +--------+    +--------------+  |
   (32-bit)      |  | AXI4-Lite |    | ECC    |    | codeword RAM |  |
                 |  | slave FSM |<==>| datapath|<=>| 72 bits wide |  |
                 |  +-----------+    +--------+    +--------------+  |
                 |        |            |    |                       |
                 |        v            v    v                       |
                 |   +---------+   encoder decoder  (from Phase 1)   |
                 |   | regs:   |                                     |
                 |   | CTRL    |   +------------------+              |
                 |   | STATUS  |<--| counters, status |              |
                 |   | counters|   +------------------+              |
                 |   | inject  |            |                        |
                 |   +---------+            v                        |
                 |                     irq_o (level)                 |
                 +---------------------------------------------------+
```

The demonstration this enables, entirely over the bus:

1. software writes a 64-bit value into the data window -> it is **encoded** and
   the 72-bit codeword is stored;
2. software **injects** a bit-flip into the stored codeword;
3. software reads the value back -> the error is **corrected**, the corrected
   data is returned, `CE_COUNT` increments;
4. software injects two flips -> the read is flagged **uncorrectable**,
   `UE_COUNT` increments, and `irq_o` asserts.

That is the whole value proposition of in-line ECC, visible from software.

---

## 2. AXI4-Lite, only the parts that matter here

AXI4-Lite is the cut-down AMBA interface for control registers: single
transfers, no bursts, no transaction IDs, no out-of-order completion. Five
independent channels, each a simple VALID/READY handshake:

| channel | direction | carries |
|---|---|---|
| AW | master -> slave | write address (`AWADDR`, `AWPROT`) |
| W  | master -> slave | write data (`WDATA`, `WSTRB` byte enables) |
| B  | slave -> master | write response (`BRESP`) |
| AR | master -> slave | read address (`ARADDR`, `ARPROT`) |
| R  | slave -> master | read data (`RDATA`, `RRESP`) |

### The handshake rule that causes most AXI bugs

A transfer happens on the rising edge where `VALID` and `READY` are both high.
The rule that is easy to get wrong:

> A source **must not** wait for `READY` before asserting `VALID`.
> A destination **may** wait for `VALID` before asserting `READY`.

So `VALID` must never combinationally depend on `READY` — that creates a
combinational loop between master and slave and deadlocks. `READY` depending on
`VALID` is legal. Once asserted, `VALID` must stay asserted until the handshake
completes; the payload must stay stable across that time.

This controller takes the safe side of that rule: all `VALID` outputs are
registered and never look at the corresponding `READY` in the same cycle.

### Responses

| `BRESP` / `RRESP` | value | used here for |
|---|---|---|
| `OKAY`   | `2'b00` | normal completion |
| `SLVERR` | `2'b10` | write aborted because the read-modify-write found an uncorrectable error; access to a reserved register |
| `DECERR` | `2'b11` | address outside the 4 KB aperture (not generated internally; the interconnect normally handles this) |

### Ordering and depth

The slave accepts **one transaction at a time** (no pipelining, no outstanding
requests). For a control interface that is the right trade: it removes a large
class of ordering bugs, and the throughput that matters is the data path, not
the register path. AW and W are accepted in either order; the write begins once
both have arrived.

---

## 3. Bus width, and the read-modify-write problem

**Decision: 32-bit AXI data bus.** This is the canonical AXI4-Lite width and it
forces an honest confrontation with a real memory-controller problem.

The ECC word is 64 data bits, protected as a single 72-bit codeword. The check
bits are computed over **all 64 data bits at once** — that is what gives
`d_min = 4`. So a 32-bit bus cannot write half a protected word independently:
there is no such thing as "the check bits for the low half".

Writing 32 bits therefore requires a **read-modify-write**:

```
1. READ    the stored 72-bit codeword for that word address
2. DECODE  it to recover the current 64-bit data (correcting if needed)
3. MERGE   the new 32 bits (masked by WSTRB) into the 64-bit data
4. ENCODE  the merged 64-bit data into a fresh 72-bit codeword
5. WRITE   the codeword back
```

**This is not an artifact of our design — it is why ECC DRAM has a partial-write
penalty.** A sub-word write to ECC-protected memory always costs a read first.
Real controllers mitigate it by caching, write combining, or by using narrower
ECC granules; none of those change the fundamental fact. Being able to explain
this is worth more than avoiding it, so the design implements it explicitly.

### The dangerous corner: RMW over corrupt data

Step 2 can fail. If the stored codeword has an **uncorrectable** error, the
recovered 64-bit data is wrong, and encoding it in step 4 would produce a
*valid codeword containing garbage* — turning a detected fault into permanent
silent corruption, with a clean syndrome, forever.

**Decision: abort the write.** On a UE during an RMW read:

- the RAM is **not** modified;
- `UE_COUNT` increments and `STATUS.UE` latches;
- the write completes with `BRESP = SLVERR`, so software is told;
- the interrupt fires if enabled.

A full-width 64-bit write (both halves, all bytes) needs no read at all, so it
is the one way to recover a word that has gone uncorrectable. That asymmetry is
intentional and documented in the register map below.

---

## 4. Address map

Aperture: **4 KB** (12 address bits). Registers in the first 256 bytes, the
protected data window in the upper half.

| offset range | contents |
|---|---|
| `0x000` - `0x0FF` | control and status registers |
| `0x100` - `0x7FF` | reserved (reads 0, writes ignored, `SLVERR`) |
| `0x800` - `0xFFF` | protected data window, 2 KB = 256 words x 64 bits |

Word address `i` of the protected memory occupies 8 bytes at
`0x800 + 8*i`: the low half at `0x800 + 8*i`, the high half at
`0x800 + 8*i + 4`.

Depth is a parameter (`MEM_DEPTH`, default 256). 256 entries x 72 bits is
chosen because it fits exactly one Artix-7 36Kb block RAM in its 512x72 wide
configuration using half the depth, so Phase 2's area report will show the ECC
logic cost rather than being swamped by distributed RAM.

---

## 5. Register map

All registers are 32 bits, little-endian, accessed at 4-byte alignment.
Access types: **RW** read/write, **RO** read-only, **WO** write-only
(reads return 0), **W1C** write-1-to-clear, **RW1C** readable, write-1-to-clear.

| offset | name | access | description |
|---|---|---|---|
| `0x00` | `ID` | RO | Block identity and version. `0xECC0_0200` (Phase 2 r0). Lets software confirm it is talking to this IP before touching anything else. |
| `0x04` | `CTRL` | RW | Global control. See bit table below. |
| `0x08` | `STATUS` | RO | Live and sticky status. See bit table below. |
| `0x0C` | `CE_COUNT` | RO | Corrected-error count, saturating at `0xFFFFFFFF`. Cleared by `CTRL.CLR_CNT`. |
| `0x10` | `UE_COUNT` | RO | Uncorrectable-error count, saturating. Cleared by `CTRL.CLR_CNT`. |
| `0x14` | `ERR_ADDR` | RO | Word index of the most recent error (CE or UE). |
| `0x18` | `ERR_SYND` | RO | `[7:0]` syndrome of the most recent error; `[15:8]` corrected bit position (`0xFF` if none); `[16]` set if the most recent error was uncorrectable. |
| `0x1C` | `IRQ_EN` | RW | Interrupt enables, one bit per source. |
| `0x20` | `IRQ_STATUS` | RW1C | Pending interrupts. Write 1 to a bit to clear it. |
| `0x24` | `INJ_ADDR` | RW | Word index targeted by an injection. |
| `0x28` | `INJ_MASK_LO` | RW | XOR mask for codeword bits `[31:0]` (data low). |
| `0x2C` | `INJ_MASK_HI` | RW | XOR mask for codeword bits `[63:32]` (data high). |
| `0x30` | `INJ_MASK_CHK` | RW | `[7:0]` XOR mask for codeword bits `[71:64]` (check bits). |
| `0x34` | `INJ_CTRL` | WO | Writing `1` to bit 0 performs the injection. |
| `0x38` - `0xFF` | reserved | - | Reads 0; access returns `SLVERR`. |

### `CTRL` (`0x04`)

| bits | name | access | description |
|---|---|---|---|
| `0` | `EN` | RW | Master enable. When 0, data-window accesses return `SLVERR` and the RAM is untouched. Registers remain accessible. Reset: 1. |
| `1` | `CORR_EN` | RW | When 1, single-bit errors are corrected on read. When 0, errors are still **detected and counted** but the raw stored data is returned uncorrected. Detect-only is a real system mode, and Phase 5 needs it to measure raw versus corrected error rates. Reset: 1. |
| `2` | `CLR_CNT` | WO | Write 1 to clear `CE_COUNT`, `UE_COUNT`, and the sticky bits in `STATUS`. Self-clearing. |
| `31:3` | reserved | RO | Reads 0, writes ignored. |

### `STATUS` (`0x08`)

| bits | name | access | description |
|---|---|---|---|
| `0` | `CE_STICKY` | RO | At least one correctable error has been seen since the last `CLR_CNT`. |
| `1` | `UE_STICKY` | RO | At least one uncorrectable error has been seen since the last `CLR_CNT`. |
| `2` | `BUSY` | RO | A read-modify-write or injection is in progress. |
| `31:3` | reserved | RO | Reads 0. |

### `IRQ_EN` (`0x1C`) and `IRQ_STATUS` (`0x20`)

Both use the same bit assignment:

| bit | name | raised when |
|---|---|---|
| `0` | `UE` | an uncorrectable error is detected on any read or RMW read |
| `1` | `CE` | a correctable error is detected and repaired |
| `2` | `CE_OVF` | `CE_COUNT` saturates |
| `31:3` | reserved | never |

`irq_o` is **level-sensitive**, asserted while `|(IRQ_STATUS & IRQ_EN)`. Level
rather than pulse because a pulse can be missed by a slow interrupt controller
or lost across a clock-domain crossing, and because level semantics make the
handler's read-then-clear sequence race-free: the handler reads
`IRQ_STATUS`, acts, writes the bits back to clear, and if a new event arrived
in between, the bit is still set and `irq_o` stays high rather than the event
being dropped.

`UE` is the interrupt that matters. A correctable error is routine
housekeeping — log it, maybe trigger a scrub — whereas an uncorrectable error
means data has been lost and software must act.

### Error injection (`0x24` - `0x34`)

Injection exists so correction can be demonstrated and characterised without
physically corrupting hardware. Real DRAM and NAND controllers ship exactly
this feature for production test.

Writing `INJ_CTRL[0] = 1` performs, on word `INJ_ADDR`:

```
codeword[71:0] <= codeword[71:0] XOR {INJ_MASK_CHK[7:0], INJ_MASK_HI, INJ_MASK_LO}
```

as a **raw read-XOR-write that bypasses the encoder entirely**. Bypassing is
the whole point: routing it through the encoder would recompute valid check
bits and erase the very error being injected.

Injection does **not** touch the counters or status. It is a fault-insertion
tool, not an error event; the counters should only reflect what the decoder
actually observes on a real access.

Setting one mask bit produces a correctable error. Setting two produces an
uncorrectable one. Setting a mask bit in `INJ_MASK_CHK` corrupts a check bit
rather than a data bit, which is worth testing separately: Phase 1 proved all
72 positions are correctable, and the check bits are 8 of those 72.

---

## 6. Transaction timing

Synchronous RAM with one-cycle read latency. Cycle counts from the acceptance
of the last required address/data beat to the response beat:

| operation | sequence | latency |
|---|---|---|
| register read | decode -> mux | 1 cycle |
| register write | decode -> update | 1 cycle |
| data read | RAM read (1) -> decode (comb) -> `RVALID` | 2 cycles |
| full 64-bit data write | encode (comb) -> RAM write | 2 cycles |
| **partial data write (RMW)** | RAM read (1) -> decode -> merge -> encode -> RAM write (1) | 4 cycles |
| injection | RAM read (1) -> XOR -> RAM write (1) | 3 cycles |

The ECC logic itself remains combinational and adds **zero cycles** — the
latency above is bus handshaking and RAM access. That preserves the Phase 1
property that matters: the engine adds propagation delay, never a stall.

Note that a 32-bit write is 4 cycles against a 2-cycle 64-bit write. That 2x
gap *is* the ECC partial-write penalty, measurable from software, and Phase 5
will quote it.

---

## 7. Phase 2 increments

Committed separately, each verified before the next begins:

| step | deliverable | verification |
|---|---|---|
| **2a** | this specification | review |
| **2b** | AXI4-Lite slave: channels, handshakes, address decode, registers. No ECC yet. | protocol testbench: handshake rules, response codes, register read/write, reserved-space `SLVERR` |
| **2c** | codeword RAM + ECC datapath: encode on write, decode on read, RMW for partial writes | self-checking TB against the Phase 1 golden model |
| **2d** | counters, sticky status, `ERR_ADDR`/`ERR_SYND`, error injection | directed tests: inject 1 bit -> CE; inject 2 -> UE + `SLVERR` on RMW; saturation; clear |
| **2e** | interrupt generation and `IRQ_EN`/`IRQ_STATUS` semantics | tests for level behaviour, masking, write-1-to-clear, and the handler race |
| **2f** | Vivado synthesis, Artix-7 `xc7a35t` | real Fmax and LUT/FF, reported for the full wrapper **and** the ECC core alone so the ECC cost is visible |
| **2g** | Phase 2 report | consolidated results |

### Open decisions deferred, deliberately

- **Scrubbing** (background walk of memory that rewrites corrected words) is a
  natural fit here and is what real DRAM controllers do to stop correctable
  errors accumulating into uncorrectable ones. It is **out of Phase 2 scope**
  and noted as a candidate addition, because it needs its own FSM, its own
  arbitration against bus traffic, and its own tests.
- **Clock domain crossing** between the bus and a separate memory clock. Phase 2
  is single-clock per the project constraints.
- **Byte-granular ECC.** Protecting each byte separately would remove the RMW
  penalty but costs far more check bits and gives weaker protection per bit.
  The 64/8 granule is the DRAM-realistic choice.
