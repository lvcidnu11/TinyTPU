package tpu_pkg;
    localparam integer ARRAY_SIZE = 8;    // N x N processing elements
    localparam integer DATA_WIDTH = 8;    // signed INT8 operands
    localparam integer ACC_WIDTH  = 32;   // INT32 accumulators, wrapping modulo 2^32
    localparam integer K_MAX      = 1024; // longest reduction held in the operand buffers

    localparam integer IDX_WIDTH  = $clog2(ARRAY_SIZE);
    localparam integer K_WIDTH    = $clog2(K_MAX);     // reduction index 0..K_MAX-1
    localparam integer KLEN_WIDTH = $clog2(K_MAX + 1); // reduction length 0..K_MAX

    // Host word address = {region, lane, index}
    //   X:   lane = activation row r,  index = reduction step i
    //   W:   lane = output column c,   index = reduction step i
    //   OUT: lane = output row r,      index = output column c
    localparam integer ADDR_WIDTH = 2 + IDX_WIDTH + K_WIDTH;
    localparam logic [1:0] REGION_X   = 2'd0;
    localparam logic [1:0] REGION_W   = 2'd1;
    localparam logic [1:0] REGION_OUT = 2'd2;

    // Cycles from the last operand read until every accumulator holds its final sum:
    // buffer read, input skew register, 2(N-1) hops, accumulator register.
    localparam integer DRAIN_CYCLES = 2 * ARRAY_SIZE;
endpackage
