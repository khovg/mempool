// Copyright 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import "DPI-C" function void read_elf (input string filename)                                ;
import "DPI-C" function byte get_section (output longint address, output longint len)        ;
import "DPI-C" context function byte read_section(input longint address, inout byte buffer[]);

module mempool_tb;

  /*****************
   *  Definitions  *
   *****************/

  timeunit      1ns;
  timeprecision 1ps;

  import mempool_pkg::*         ;
  import axi_pkg::xbar_cfg_t    ;
  import axi_pkg::xbar_rule_32_t;

  localparam        NumCores        = 256;
  localparam        NumCoresPerTile = 4;
  localparam        BankingFactor   = 4;
  localparam addr_t TCDMBaseAddr    = '0;
  localparam        TCDMSizePerBank = 1024 /* [B] */;
  localparam        NumTiles        = NumCores / NumCoresPerTile;
  localparam        NumBanks        = NumCores * BankingFactor;
  localparam        TCDMSize        = NumBanks * TCDMSizePerBank;

  localparam ClockPeriod = 1ns;
  localparam TA          = 0.2ns;
  localparam TT          = 0.8ns;

  localparam L2AddrWidth = 18;

  /*********
   *  AXI  *
   *********/

  `include "axi/assign.svh"
  `include "axi/typedef.svh"

  localparam AxiMstIdWidth = $clog2(NumCoresPerTile);
  localparam AxiSlvIdWidth = $clog2(NumCores);

  typedef logic [AxiMstIdWidth-1:0] axi_mst_id_t;
  typedef logic [AxiSlvIdWidth-1:0] axi_slv_id_t;

  `AXI_TYPEDEF_AW_CHAN_T(axi_aw_t, addr_t, axi_mst_id_t, logic);
  `AXI_TYPEDEF_W_CHAN_T(axi_w_t, data_t, strb_t, logic)        ;
  `AXI_TYPEDEF_B_CHAN_T(axi_b_t, axi_mst_id_t, logic)          ;
  `AXI_TYPEDEF_AR_CHAN_T(axi_ar_t, addr_t, axi_mst_id_t, logic);
  `AXI_TYPEDEF_R_CHAN_T(axi_r_t, data_t, axi_mst_id_t, logic)  ;
  `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_t, axi_w_t, axi_ar_t)   ;
  `AXI_TYPEDEF_RESP_T(axi_resp_t, axi_b_t, axi_r_t )           ;

  `AXI_TYPEDEF_AW_CHAN_T(axi_slv_aw_t, addr_t, axi_slv_id_t, logic)     ;
  `AXI_TYPEDEF_W_CHAN_T(axi_slv_w_t, data_t, strb_t, logic)             ;
  `AXI_TYPEDEF_B_CHAN_T(axi_slv_b_t, axi_slv_id_t, logic)               ;
  `AXI_TYPEDEF_AR_CHAN_T(axi_slv_ar_t, addr_t, axi_slv_id_t, logic)     ;
  `AXI_TYPEDEF_R_CHAN_T(axi_slv_r_t, data_t, axi_slv_id_t, logic)       ;
  `AXI_TYPEDEF_REQ_T(axi_slv_req_t, axi_slv_aw_t, axi_w_t, axi_slv_ar_t);
  `AXI_TYPEDEF_RESP_T(axi_slv_resp_t, axi_slv_b_t, axi_slv_r_t)         ;

  localparam NumAXIMasters = NumTiles;
  localparam NumAXISlaves  = 4;
  typedef enum logic [$clog2(NumAXISlaves)-1:0] {
    CtrlRegisters,
    L2Memory     ,
    UART         ,
    EOC
  } axi_slave_target;

  localparam xbar_cfg_t XBarCfg = '{
    NoSlvPorts        : NumAXIMasters         ,
    NoMstPorts        : NumAXISlaves          ,
    MaxMstTrans       : 4                     ,
    MaxSlvTrans       : 4                     ,
    FallThrough       : 1'b0                  ,
    LatencyMode       : axi_pkg::CUT_MST_PORTS,
    AxiIdWidthSlvPorts: AxiMstIdWidth         ,
    AxiIdUsedSlvPorts : AxiMstIdWidth         ,
    AxiAddrWidth      : AddrWidth             ,
    AxiDataWidth      : DataWidth             ,
    NoAddrRules       : NumAXISlaves
  };

  axi_req_t     [NumAXIMasters-1:0] axi_mst_req_o;
  axi_resp_t    [NumAXIMasters-1:0] axi_mst_resp_i;
  axi_slv_req_t [NumAXISlaves-1:0]  axi_mem_req;
  axi_slv_resp_t[NumAXISlaves-1:0]  axi_mem_resp;

  /********************************
   *  Clock and Reset Generation  *
   ********************************/

  logic clk ;
  logic rst_n;

  // Toggling the clock
  always #(ClockPeriod/2) clk = !clk;

  // Controlling the reset
  initial begin
    clk   = 1'b1;
    rst_n = 1'b0;

    repeat (5)
      #(ClockPeriod);

    rst_n = 1'b1;
  end

  /*********
   *  DUT  *
   *********/

  mempool #(
    .NumCores       (NumCores       ),
    .NumCoresPerTile(NumCoresPerTile),
    .BankingFactor  (BankingFactor  ),
    .TCDMBaseAddr   (TCDMBaseAddr   ),
    .TCDMSizePerBank(TCDMSizePerBank),
    .BootAddr       (32'h8001_0000  ),
    .axi_aw_t       (axi_aw_t       ),
    .axi_w_t        (axi_w_t        ),
    .axi_b_t        (axi_b_t        ),
    .axi_ar_t       (axi_ar_t       ),
    .axi_r_t        (axi_r_t        ),
    .axi_req_t      (axi_req_t      ),
    .axi_resp_t     (axi_resp_t     )
  ) dut (
    .clk_i          (clk           ),
    .rst_ni         (rst_n         ),
    .axi_mst_req_o  (axi_mst_req_o ),
    .axi_mst_resp_i (axi_mst_resp_i),
    .scan_enable_i  (1'b0          ),
    .scan_data_i    (1'b0          ),
    .scan_data_o    (/* Unused */  )
  );

  /**********************
   *  AXI Interconnect  *
   **********************/

  localparam addr_t CtrlRegistersBaseAddr = 32'h4000_0000;
  localparam addr_t CtrlRegistersEndAddr  = 32'h4000_FFFF;
  localparam addr_t L2MemoryBaseAddr      = 32'h8000_0000;
  localparam addr_t L2MemoryEndAddr       = 32'hBFFF_FFFF;
  localparam addr_t UARTBaseAddr          = 32'hC000_0000;
  localparam addr_t UARTEndAddr           = 32'hC000_FFFF;
  localparam addr_t EOCBaseAddr           = 32'hD000_0000;
  localparam addr_t EOCEndAddr            = 32'hD000_FFFF;

  xbar_rule_32_t [NumAXISlaves-1:0] tb_xbar_routing_rules = '{
    '{idx: CtrlRegisters, start_addr: CtrlRegistersBaseAddr, end_addr: CtrlRegistersEndAddr},
    '{idx: L2Memory, start_addr: L2MemoryBaseAddr, end_addr: L2MemoryEndAddr}               ,
    '{idx: UART, start_addr: UARTBaseAddr, end_addr: UARTEndAddr}                           ,
    '{idx: EOC, start_addr: EOCBaseAddr, end_addr: EOCEndAddr}};

  axi_xbar #(
    .Cfg           (XBarCfg       ),
    .slv_aw_chan_t (axi_aw_t      ),
    .mst_aw_chan_t (axi_slv_aw_t  ),
    .w_chan_t      (axi_w_t       ),
    .slv_b_chan_t  (axi_b_t       ),
    .mst_b_chan_t  (axi_slv_b_t   ),
    .slv_ar_chan_t (axi_ar_t      ),
    .mst_ar_chan_t (axi_slv_ar_t  ),
    .slv_r_chan_t  (axi_r_t       ),
    .mst_r_chan_t  (axi_slv_r_t   ),
    .slv_req_t     (axi_req_t     ),
    .slv_resp_t    (axi_resp_t    ),
    .mst_req_t     (axi_slv_req_t ),
    .mst_resp_t    (axi_slv_resp_t),
    .rule_t        (xbar_rule_32_t)
  ) i_tesbench_xbar (
    .clk_i                 (clk                  ),
    .rst_ni                (rst_n                ),
    .test_i                (1'b0                 ),
    .slv_ports_req_i       (axi_mst_req_o        ),
    .slv_ports_resp_o      (axi_mst_resp_i       ),
    .mst_ports_req_o       (axi_mem_req          ),
    .mst_ports_resp_i      (axi_mem_resp         ),
    .addr_map_i            (tb_xbar_routing_rules),
    .en_default_mst_port_i ('0                   ),
    .default_mst_port_i    ('0                   )
  );

  /********
   *  L2  *
   ********/

  AXI_BUS #(
    .AXI_ADDR_WIDTH (AddrWidth    ),
    .AXI_DATA_WIDTH (DataWidth    ),
    .AXI_ID_WIDTH   (AxiSlvIdWidth),
    .AXI_USER_WIDTH (1            )
  ) axi_l2memory_slave ();

  // Assign slave
  `AXI_ASSIGN_FROM_REQ(axi_l2memory_slave, axi_mem_req[L2Memory] );
  `AXI_ASSIGN_TO_RESP (axi_mem_resp[L2Memory], axi_l2memory_slave);

  // Memory
  logic  mem_req;
  addr_t mem_addr;
  data_t mem_wdata;
  strb_t mem_strb;
  data_t mem_strb_int;
  logic  mem_we;
  data_t mem_rdata;

  axi2mem #(
    .AXI_ADDR_WIDTH(AddrWidth    ),
    .AXI_DATA_WIDTH(DataWidth    ),
    .AXI_ID_WIDTH  (AxiSlvIdWidth),
    .AXI_USER_WIDTH(1            )
  ) i_axi2mem (
    .clk_i (clk               ),
    .rst_ni(rst_n             ),
    .slave (axi_l2memory_slave),
    .req_o (mem_req           ),
    .addr_o(mem_addr          ),
    .data_o(mem_wdata         ),
    .we_o  (mem_we            ),
    .be_o  (mem_strb          ),
    .data_i(mem_rdata         )
  );

  for (genvar be_byte = 0; be_byte < BeWidth; be_byte++) begin: gen_mem_be
    assign mem_strb_int[8*be_byte+:8] = {8{mem_strb[be_byte]}};
  end

  sram #(
    .DATA_WIDTH(DataWidth     ),
    .NUM_WORDS (2**L2AddrWidth)
  ) l2_mem (
    .clk_i  (clk                                ),
    .req_i  (mem_req                            ),
    .we_i   (mem_we                             ),
    .addr_i (mem_addr[ByteOffset +: L2AddrWidth]),
    .wdata_i(mem_wdata                          ),
    .be_i   (mem_strb_int                       ),
    .rdata_o(mem_rdata                          )
  );

  /**********
   *  UART  *
   **********/

  // Printing
  axi_slv_id_t id_queue [$];

  initial begin
    automatic string sb = "";

    axi_mem_resp[UART] <= '0;
    while (1) begin
      @(posedge clk); #TT;
      fork
        begin
          wait(axi_mem_req[UART].aw_valid);
          axi_mem_resp[UART].aw_ready <= 1'b1;
          axi_mem_resp[UART].aw_ready <= @(posedge clk) 1'b0;
          id_queue.push_back(axi_mem_req[UART].aw.id);
        end
        begin
          wait(axi_mem_req[UART].w_valid);
          axi_mem_resp[UART].w_ready <= 1'b1;
          axi_mem_resp[UART].w_ready <= @(posedge clk) 1'b0;
          $write("%c", axi_mem_req[UART].w.data);
        end
      join

      // Send response
      axi_mem_resp[UART].b_valid = 1'b1                ;
      axi_mem_resp[UART].b.id    = id_queue.pop_front();
      axi_mem_resp[UART].b.resp  = axi_pkg::RESP_OKAY  ;
      axi_mem_resp[UART].b.user  = '0                  ;
      wait(axi_mem_req[UART].b_ready);
      @(posedge clk);
      axi_mem_resp[UART].b_valid = 1'b0;
    end
  end

  /*********
   *  EOC  *
   *********/

  initial begin
    axi_mem_resp[EOC] <= '0;

    while (1) begin
      @(posedge clk); #TT;
      fork
        begin
          wait(axi_mem_req[EOC].aw_valid);
          axi_mem_resp[EOC].aw_ready <= 1'b1;
          axi_mem_resp[EOC].aw_ready <= @(posedge clk) 1'b0;
        end
        begin
          wait(axi_mem_req[EOC].w_valid)                                                          ;
          // Finish simulation
          $timeformat(-9, 2, " ns", 0)                                                            ;
          $display("[EOC] Simulation ended at %t (retval = %0d).", $time, axi_mem_req[EOC].w.data);
          $finish(0)                                                                              ;
        end
      join
    end
  end

  /***********************
   *  Control Registers  *
   ***********************/

  ctrl_registers #(
    .NumRegs              (3                    ),
    .TCDMBaseAddr         (TCDMBaseAddr         ),
    .TCDMSize             (TCDMSize             ),
    .NumCores             (NumCores             ),
    .CtrlRegistersBaseAddr(CtrlRegistersBaseAddr),
    .CtrlRegistersEndAddr (CtrlRegistersEndAddr ),
    .axi_aw_chan_t        (axi_slv_aw_t         ),
    .axi_w_chan_t         (axi_w_t              ),
    .axi_b_chan_t         (axi_slv_b_t          ),
    .axi_ar_chan_t        (axi_slv_ar_t         ),
    .axi_r_chan_t         (axi_slv_r_t          ),
    .axi_req_t            (axi_slv_req_t        ),
    .axi_resp_t           (axi_slv_resp_t       )
  ) i_ctrl_registers (
    .clk_i               (clk                        ),
    .rst_ni              (rst_n                      ),
    .axi_slave_req_i     (axi_mem_req[CtrlRegisters] ),
    .axi_slave_resp_o    (axi_mem_resp[CtrlRegisters]),
    .tcdm_start_address_o(/* Unused */               ),
    .tcdm_end_address_o  (/* Unused */               ),
    .num_cores_o         (/* Unused */               )
  );

  /************************
   *  Instruction Memory  *
   ************************/

  localparam addr_t ICacheLineWidth   = dut.gen_tiles[0].i_tile.i_snitch_icache.LINE_WIDTH;
  localparam addr_t ICacheBytes       = ICacheLineWidth / 8 ;
  localparam addr_t ICacheAddressMask = ~(ICacheBytes - 1);
  localparam addr_t ICacheByteOffset  = $clog2(ICacheBytes);

  logic [ICacheLineWidth-1:0] instr_memory[addr_t];

  for (genvar t = 0; t < NumTiles; t++) begin: drive_inst_mem
    static addr_t address       = '0;
    static integer unsigned len = '0;

    initial begin
      while (1) begin
        @(posedge clk);
        #TA
        if (dut.gen_tiles[t].i_tile.refill_qvalid_o) begin
          // Respond to request
          address = dut.gen_tiles[t].i_tile.refill_qaddr_o;
          len     = dut.gen_tiles[t].i_tile.refill_qlen_o ;

          cache_line_alignment: assume ((address & ICacheAddressMask) == address)
          else $fatal(1, "Tile %0d request instruction at %x, but we only support cache-line boundary addresses.", t, address);

          force dut.gen_tiles[t].i_tile.refill_qready_i = 1'b1;
          @(posedge clk);
          force dut.gen_tiles[t].i_tile.refill_qready_i = 1'b0;
          // Response
          for (int i = 0; i < len; i++) begin
            force dut.gen_tiles[t].i_tile.refill_pdata_i  = instr_memory[address];
            force dut.gen_tiles[t].i_tile.refill_pvalid_i = 1'b1                 ;
            force dut.gen_tiles[t].i_tile.refill_plast_i  = 1'b0                 ;
            address += ICacheBytes                     ;
            wait(dut.gen_tiles[t].i_tile.refill_pready_o);
            @(posedge clk);
          end
          // Last response
          force dut.gen_tiles[t].i_tile.refill_pdata_i  = instr_memory[address];
          force dut.gen_tiles[t].i_tile.refill_pvalid_i = 1'b1                 ;
          force dut.gen_tiles[t].i_tile.refill_plast_i  = 1'b1                 ;
          wait(dut.gen_tiles[t].i_tile.refill_pready_o);
          @(posedge clk);
          force dut.gen_tiles[t].i_tile.refill_pvalid_i = 1'b0;
          force dut.gen_tiles[t].i_tile.refill_plast_i  = 1'b0;
        end else begin
          force dut.gen_tiles[t].i_tile.refill_pdata_i  = '0  ;
          force dut.gen_tiles[t].i_tile.refill_qready_i = 1'b0;
        end
      end
    end
  end

  /***************************
   *  Memory Initialization  *
   ***************************/

  initial begin : instr_memory_init
    automatic logic [ICacheLineWidth-1:0] mem_row;
    byte buffer []                               ;
    addr_t address                               ;
    addr_t length                                ;
    string binary                                ;

    // Initialize memories
    void'($value$plusargs("PRELOAD=%s", binary));
    if (binary != "") begin
      // Read ELF
      void'(read_elf(binary))       ;
      $display("Loading %s", binary);
      while (get_section(address, length)) begin
        // Read sections
        automatic int nwords = (length + ICacheBytes - 1)/ICacheBytes ;
        $display("Loading section %x of length %x", address, length) ;
        buffer = new[nwords * ICacheBytes] ;
        void'(read_section(address, buffer));
        // Initializing memories
        for (int w = 0; w < nwords; w++) begin
          mem_row = '0;
          for (int b = 0; b < ICacheBytes; b++) begin
            mem_row[8 * b +: 8] = buffer[w * ICacheBytes + b];
          end
          instr_memory[address + (w << ICacheByteOffset)] = mem_row;
        end
      end
    end
  end : instr_memory_init

  initial begin : l2_init
    automatic data_t mem_row;
    byte buffer []          ;
    addr_t address          ;
    addr_t length           ;
    string binary           ;

    // Initialize memories
    void'($value$plusargs("PRELOAD=%s", binary));
    if (binary != "") begin
      // Read ELF
      void'(read_elf(binary))       ;
      $display("Loading %s", binary);
      while (get_section(address, length)) begin
        // Read sections
        automatic int nwords = (length + BeWidth - 1)/BeWidth ;
        $display("Loading section %x of length %x", address, length);
        buffer = new[nwords * BeWidth] ;
        void'(read_section(address, buffer));
        // Initializing memories
        for (int w = 0; w < nwords; w++) begin
          mem_row = '0;
          for (int b = 0; b < BeWidth; b++) begin
            mem_row[8 * b +: 8] = buffer[w * BeWidth + b];
          end
          if (address >= L2MemoryBaseAddr && address < L2MemoryEndAddr)
            l2_mem.ram[(address - L2MemoryBaseAddr + (w << ByteOffset)) >> ByteOffset] = mem_row;
          else
            $display("Cannot initialize address %x, which doesn't fall into the L2 region.", address);
        end
      end
    end
  end : l2_init

endmodule : mempool_tb
