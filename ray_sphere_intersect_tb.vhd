----------------------------------------------------------------------------
--
--  TODO
-- 
--  Revision History:
--     01 May 25    Zack Huang      initial revision
--
----------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.types.all;

entity ray_sphere_intersect_tb is
end ray_sphere_intersect_tb;

architecture behavioral of ray_sphere_intersect_tb is
    -- Stimulus signals for unit under test
    signal ray_in     : Ray;
    signal sphere_in  : Sphere;
    signal clock      : std_logic;

    -- Outputs from unit under test
    signal data_out     : IntersectionData;

begin
    -- Instantiate UUT
    UUT: entity work.RaySphereIntersect
    port map(
        ray_in => ray_in,
        sphere_in => sphere_in,
        clock => clock,
        data_out => data_out
    );

    process is

        procedure Tick is
        begin
            clock <= '0';
            wait for 10 ns;
            clock <= '1';
            wait for 10 ns;
        end procedure Tick;

    begin
        ray_in <= (
            origin => (x => 0.0, y => 0.0, z => 0.0),
            direction => (x => 1.0, y => 0.0, z => 0.0)
        );
        sphere_in <= (
            center => (x => 10.0, y => 0.0, z => 0.0),
            radius => 10.0
        );

        Tick;

        report "Is hit: " & to_string(data_out.hit);

        wait;
    end process;
end behavioral;
