import tpu_pkg::*;

// IDLE --start--> COMPUTE (one operand column per cycle, k cycles)
//               -> DRAIN (DRAIN_CYCLES) -> DONE (one-cycle pulse) -> IDLE
// k = 0 goes straight to DONE with cleared accumulators.
module tpu_fsm (
    input  logic i_clk,
    input  logic i_rst_n,

    input  logic i_start,
    input  logic [KLEN_WIDTH-1:0] i_k,
    output logic o_done,
    output logic o_busy,

    output logic o_clear,
    output logic o_rd_enable,
    output logic [K_WIDTH-1:0] o_rd_index
);

    localparam int DRAIN_W = $clog2(DRAIN_CYCLES);

    typedef enum logic [1:0] {
        S_IDLE, S_COMPUTE, S_DRAIN, S_DONE
    } state_t;

    state_t state, next_state;

    logic [KLEN_WIDTH-1:0] k_clamped;
    logic [KLEN_WIDTH-1:0] k_last;   // k - 1, latched at start
    logic [K_WIDTH-1:0] rd_cnt;
    logic [DRAIN_W-1:0] drain_cnt;

    assign k_clamped = (i_k > KLEN_WIDTH'(K_MAX)) ? KLEN_WIDTH'(K_MAX) : i_k;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            k_last <= '0;
            rd_cnt <= '0;
            drain_cnt <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    k_last <= k_clamped - 1'd1;
                    rd_cnt <= '0;
                    drain_cnt <= '0;
                end
                S_COMPUTE:
                    rd_cnt <= rd_cnt + 1'd1;
                S_DRAIN:
                    drain_cnt <= drain_cnt + 1'd1;
                default: begin
                    rd_cnt <= '0;
                    drain_cnt <= '0;
                end
            endcase
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            S_IDLE:
                if (i_start && k_clamped == '0)
                    next_state = S_DONE;
                else if (i_start)
                    next_state = S_COMPUTE;
            S_COMPUTE:
                if ({1'b0, rd_cnt} == k_last)
                    next_state = S_DRAIN;
            S_DRAIN:
                if (drain_cnt == DRAIN_W'(DRAIN_CYCLES - 1))
                    next_state = S_DONE;
            S_DONE:
                next_state = S_IDLE;
            default:
                next_state = S_IDLE;
        endcase
    end

    assign o_busy = (state != S_IDLE);
    assign o_done = (state == S_DONE);
    assign o_clear = (state == S_IDLE) && i_start;
    assign o_rd_enable = (state == S_COMPUTE);
    assign o_rd_index = rd_cnt;

endmodule
