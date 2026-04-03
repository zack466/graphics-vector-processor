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
use work.util.all;

entity ray_sphere_intersect_tb is
end ray_sphere_intersect_tb;

architecture behavioral of ray_sphere_intersect_tb is
    -- Stimulus signals for unit under test
    signal ray_in     : Ray;
    signal sphere_in  : Sphere;
    signal clock      : std_logic;

    -- Outputs from unit under test
    signal data_out     : IntersectionData;

    -- Returns a camera type that is looking at a point from some position
    pure function point_camera(position : Vec3; lookAt : Vec3; up : Vec3; fov : Real; aspect : Real) return Camera is
        variable forward : Vec3;
        variable right : Vec3;
        variable true_up : Vec3;
    begin
        forward := normalize(sub(lookAt, position));
        right := normalize(cross(forward, normalize(up)));
        true_up := normalize(cross(right, forward));
        return (
            position => position,
            forward => forward,
            up => true_up,
            right => right,
            fov => fov,
            aspect => aspect
        );
    end function;

    type pixels is array (natural range <>) of std_logic_vector;

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

        variable cam : Camera;

        constant height : integer := 480;
        constant width : integer := 640;

        variable half_height : real;
        variable half_width : real;

        variable u : real;
        variable v : real;

        variable direction : Vec3;

        variable image : pixels(1 to height)(1 to width);

        procedure write_ppm(filename : string) is
            file f         : text;          -- file out
            variable l     : line;          -- current line in file
            variable pixel : std_logic;     -- current pixel of interest
            variable row_string : string(1 to WIDTH * 6);
        begin
            file_open(f, filename, write_mode);

            -- Write PPM header
            write(l, "P3" & LF);
            write(l, "# B/W Image" & LF);
            write(l, to_string(width) & " " & to_string(height) & LF);
            write(l, "1" & LF);   -- max pixel value is 1
            writeline(f, l);

            -- Write pixel data
            for y in 1 to height loop
                for x in 1 to width loop
                    -- Draw pixel (0 for black, 1 for white)
                    pixel := image(y)(x);
                    -- Collect pixels into a string for each row
                    row_string(1 + (x - 1) * 6 to x * 6) :=
                             to_string(pixel) & " " &  -- R
                             to_string(pixel) & " " &  -- G
                             to_string(pixel) & " ";   -- B
                end loop;
                write(l, row_string);   -- write a single row of pixels
                writeline(f, l);
            end loop;
            file_close(f);  -- finished writing
        end procedure;

    begin

        cam := point_camera(
                    (x => 0.0, y => 0.0, z => 0.0),
                    (x => 1.0, y => 0.0, z => 0.0),
                    (x => 0.0, y => 1.0, z => 0.0),
                    MATH_PI / 3.0,
                    real(width) / real(height)
               );

        half_height := tan(cam.fov / 2.0);
        half_width := cam.aspect * half_height;
        
        sphere_in <= (
            center => (x => 10.0, y => 0.0, z => 0.0),
            radius => 3.0
        );

        for i in 1 to width loop
            for j in 1 to height loop
                -- Calculate normalized device coordinates (-1 to 1)
                u := (2.0 * (real(i) - 0.5) / real(width) - 1.0) * half_width;
                v := (1.0 - 2.0 * (real(j) - 0.5) / real(height)) * half_height;
                
                -- Calculate ray direction in world space
                direction := normalize(
                    add(cam.forward,
                        add(mul(u, cam.right),
                            mul(v, cam.up)))
                );
                
                -- Create ray from camera position in calculated direction
                ray_in <= (origin => cam.position, direction => direction);
                
                Tick;

                -- Draw pixel based on intersection
                image(j)(i) := data_out.hit;

            end loop;
        end loop;

        write_ppm("sphere.ppm");

        wait;
    end process;
end behavioral;
