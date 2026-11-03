`timescale 1ns/1ps
import tpu_pkg::*;

// Self-checking testbench for the TinyTPU tile.
// Golden model: out[r][c] = sum_i X[r][i] * W[c][i] mod 2^32 (xtpu / tile.h semantics).
module tb_tpu;
    localparam int N = ARRAY_SIZE;
    // Busy cycles, DONE included: k operand reads + DRAIN_CYCLES + 1 (k = 0 finishes in 1).
    localparam int LATENCY_OVERHEAD = DRAIN_CYCLES + 1;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic [KLEN_WIDTH-1:0] k_len = '0;
    logic done, busy;
    logic host_we = 1'b0;
    logic [ADDR_WIDTH-1:0] host_waddr = '0;
    logic [DATA_WIDTH-1:0] host_wdata = '0;
    logic host_wready;
    logic host_re = 1'b0;
    logic [ADDR_WIDTH-1:0] host_raddr = '0;
    logic [ACC_WIDTH-1:0] host_rdata;
    logic host_rvalid;

    tpu dut (
        .i_clk          (clk),
        .i_rst_n        (rst_n),
        .i_start        (start),
        .i_k            (k_len),
        .o_done         (done),
        .o_busy         (busy),
        .i_host_wenable (host_we),
        .i_host_waddr   (host_waddr),
        .i_host_wdata   (host_wdata),
        .o_host_wready  (host_wready),
        .i_host_renable (host_re),
        .i_host_raddr   (host_raddr),
        .o_host_rdata   (host_rdata),
        .o_host_valid   (host_rvalid)
    );

    always #5 clk = ~clk;

    int x_ref [N][K_MAX];
    int w_ref [N][K_MAX];
    int checks = 0;
    int errors = 0;
    int unsigned seed = 32'h7e57_7a11;

    function automatic logic [ADDR_WIDTH-1:0] addr(input logic [1:0] region, input int lane, input int index);
        return {region, IDX_WIDTH'(lane), K_WIDTH'(index)};
    endfunction

    task automatic host_write(input logic [1:0] region, input int lane, input int index, input int value);
        host_we <= 1'b1;
        host_waddr <= addr(region, lane, index);
        host_wdata <= DATA_WIDTH'(value);
        @(posedge clk);
        host_we <= 1'b0;
    endtask

    task automatic host_read(input int row, input int col, output logic [ACC_WIDTH-1:0] value);
        host_re <= 1'b1;
        host_raddr <= addr(REGION_OUT, row, col);
        @(posedge clk);
        host_re <= 1'b0;
        @(negedge clk);
        if (!host_rvalid) begin
            $display("FAIL: read (%0d,%0d) returned no valid", row, col);
            errors++;
        end
        value = host_rdata;
    endtask

    task automatic load_operands(input int k);
        for (int i = 0; i < k; i++)
            for (int lane = 0; lane < N; lane++) begin
                host_write(REGION_X, lane, i, x_ref[lane][i]);
                host_write(REGION_W, lane, i, w_ref[lane][i]);
            end
    endtask

    task automatic run_tile(input int k_request, input int k_effective, input string name);
        int cycles;
        int expected_cycles;
        logic [N*N*ACC_WIDTH-1:0] at_done;
        logic [ACC_WIDTH-1:0] got;
        longint sum;
        logic [ACC_WIDTH-1:0] expected;

        k_len <= KLEN_WIDTH'(k_request);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        cycles = 0;
        do begin
            @(negedge clk);
            if (busy)
                cycles++;
            if (cycles > K_MAX + 100) begin
                $display("FAIL: %s timed out", name);
                $fatal(1);
            end
        end while (!done);
        at_done = dut.acc_bus; // contract: every sum is final while o_done is high
        expected_cycles = (k_effective == 0) ? 1 : k_effective + LATENCY_OVERHEAD;
        checks++;
        if (cycles != expected_cycles) begin
            $display("FAIL: %s latency %0d, expected %0d", name, cycles, expected_cycles);
            errors++;
        end
        @(posedge clk);

        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++) begin
                sum = 0;
                for (int i = 0; i < k_effective; i++)
                    sum += longint'(x_ref[r][i]) * longint'(w_ref[c][i]);
                expected = sum[ACC_WIDTH-1:0];
                checks++;
                if (at_done[(r*N + c)*ACC_WIDTH +: ACC_WIDTH] !== expected) begin
                    if (errors < 10)
                        $display("FAIL: %s out[%0d][%0d] not final at done", name, r, c);
                    errors++;
                end
                host_read(r, c, got);
                checks++;
                if (got !== expected) begin
                    if (errors < 10)
                        $display("FAIL: %s out[%0d][%0d] = %0d, expected %0d", name, r, c,
                                 $signed(got), $signed(expected));
                    errors++;
                end
            end
        $display("  %-28s k=%4d  latency=%4d cycles", name, k_effective, cycles);
    endtask

    task automatic randomize_operands(input int k);
        for (int lane = 0; lane < N; lane++)
            for (int i = 0; i < k; i++) begin
                x_ref[lane][i] = $signed(DATA_WIDTH'($urandom()));
                w_ref[lane][i] = $signed(DATA_WIDTH'($urandom()));
            end
    endtask

    task automatic fill_operands(input int k, input int x_value, input int w_value);
        for (int lane = 0; lane < N; lane++)
            for (int i = 0; i < k; i++) begin
                x_ref[lane][i] = x_value;
                w_ref[lane][i] = w_value;
            end
    endtask

    int k_values [8] = '{1, 7, 8, 9, 192, 197, 768, 1024};

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("build/tb_tpu.vcd");
            $dumpvars(0, tb_tpu);
        end

        void'($urandom(seed));
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        $display("TinyTPU %0dx%0d INT%0d tile, K_MAX=%0d", N, N, DATA_WIDTH, K_MAX);

        // Random tiles across the reduction lengths exercised by the Spike model.
        foreach (k_values[t]) begin
            randomize_operands(k_values[t]);
            load_operands(k_values[t]);
            run_tile(k_values[t], k_values[t], $sformatf("random k=%0d", k_values[t]));
        end

        // Accumulators clear between back-to-back tiles on the same operands.
        run_tile(5, 5, "rerun shorter k");

        // k = 0 writes zeros even after a non-zero tile.
        run_tile(0, 0, "k=0 clears");

        // INT8 extremes: (-128)(-128) and (-128)(127) over the longest reduction.
        fill_operands(K_MAX, -128, -128);
        load_operands(K_MAX);
        run_tile(K_MAX, K_MAX, "extrema -128 x -128");
        fill_operands(K_MAX, -128, 127);
        load_operands(K_MAX);
        run_tile(K_MAX, K_MAX, "extrema -128 x 127");

        // Requests beyond K_MAX are clamped.
        run_tile((1 << KLEN_WIDTH) - 1, K_MAX, "k clamp to K_MAX");

        // Host writes and a second start are ignored while busy.
        randomize_operands(64);
        load_operands(64);
        k_len <= KLEN_WIDTH'(64);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        @(negedge clk);
        checks++;
        if (host_wready) begin
            $display("FAIL: wready high while busy");
            errors++;
        end
        for (int i = 0; i < 16; i++) begin
            host_write(REGION_X, i % N, i, 99);
            start <= 1'b1;
        end
        start <= 1'b0;
        do @(negedge clk); while (!done);
        @(posedge clk);
        run_tile(64, 64, "busy writes ignored");

        if (errors == 0) begin
            $display("PASS: %0d checks", checks);
            $finish;
        end
        $display("FAIL: %0d errors in %0d checks", errors, checks);
        $fatal(1);
    end
endmodule
