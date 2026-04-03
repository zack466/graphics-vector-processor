------------------------------------------------------------------------------
--
--  TODO
--
--  Revision History:
--     TODO
--
------------------------------------------------------------------------------

-- import libraries
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;
use work.util.all;

entity RaySphereIntersect is
    port (
        ray_in      : in  Ray;
        sphere_in   : in  Sphere;
        clock       : in  std_logic;
        data_out    : out IntersectionData
    );
end RaySphereIntersect;

architecture behavioral of RaySphereIntersect is

begin

    process(ray_in, sphere_in, clock)
        variable oc : Vec3;
        variable a : real;
        variable b : real;
        variable c : real;

        variable t1 : real;
        variable t2 : real;

        variable discriminant : real;

        variable position : Vec3;
        variable normal : Vec3;
    
    begin
        -- Only perform calculation once all inputs are initialized, otherwise
        -- will lead to a bound check error due to uninitialized floats having
        -- extremely large values.
        if rising_edge(clock) then

            -- vector from ray origin to sphere center
            --  LDS.QW R0, ray_in.origin
            --  LDS.QW R1, sphere_in.center
            --  SUB R0, R1, R2
            oc := sub(ray_in.origin, sphere_in.center);

            -- quadratic equation coeffs
            --  LDS.QW R3, ray_in.direction
            --  DOT R3, R3, R4
            a := dot(ray_in.direction, ray_in.direction);

            --  DOT R2, R3, R5
            --  SCALEI 2.0, R5, R6
            b := 2.0 * dot(oc, ray_in.direction);

            --  LDS.W sphere_in_radius, R7
            --  MUL R7, R7, R7
            --  DOT R2, R2, R2
            --  SUB R2, R7, R7
            c := dot(oc, oc) - sphere_in.radius * sphere_in.radius;

            discriminant := b * b - 4.0 * a * c;

            if discriminant < 0.0 then
                data_out <= (
                    hit => '0',
                    position => VEC3_ZERO,
                    normal => VEC3_ZERO
                );
            else
                t1 := (-b - sqrt(discriminant)) / (2.0 * a);
                t2 := (-b + sqrt(discriminant)) / (2.0 * a);
                if t1 > 0.0001 then
                    position := add(ray_in.origin, mul(t1, ray_in.direction));
                    normal := normalize(sub(position, sphere_in.center));
                    data_out <= (
                        hit => '1',
                        position => position,
                        normal => normal
                    );
                elsif t2 > 0.0001 then
                    position := add(ray_in.origin, mul(t2, ray_in.direction));
                    normal := normalize(sub(position, sphere_in.center));
                    data_out <= (
                        hit => '1',
                        position => position,
                        normal => normal
                    );
                else
                    data_out <= (
                        hit => '0',
                        position => VEC3_ZERO,
                        normal => VEC3_ZERO
                    );
                end if;
            end if;
        end if;
    end process;

end behavioral;
