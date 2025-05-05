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

entity RaySphereIntersect is
    port (
        ray_in      : in  Ray;
        sphere_in   : in  Sphere;
        clock       : in  std_logic;
        data_out    : out IntersectionData
    );
end RaySphereIntersect;

architecture behavioral of RaySphereIntersect is

    pure function add(u : Vec3; v : Vec3) return Vec3 is
    begin
        return (
            x => u.x + v.x,
            y => u.y + v.y,
            z => u.z + v.z
        );
    end function;

    pure function sub(u : Vec3; v : Vec3) return Vec3 is
    begin
        return (
            x => u.x - v.x,
            y => u.y - v.y,
            z => u.z - v.z
        );
    end function;

    pure function dot(u : Vec3; v : Vec3) return real is
    begin
        return u.x * v.x + u.y * v.y + u.z * v.z;
    end function;

    pure function mul(s : real; v : Vec3) return Vec3 is
    begin
        return (
            x => s * v.x,
            y => s * v.y,
            z => s * v.z
        );
    end function;

    pure function norm(v : Vec3) return real is
    begin
        return sqrt(dot(v, v));
    end function;

    pure function normalize(v : Vec3) return Vec3 is
        variable n : real;
    begin
        n := norm(v);
        if n > 0.0 then
            return mul(1.0 / n, v);
        else
            return v;
        end if;
    end function;

    procedure print_vec3(v : Vec3) is
    begin
        report "(" & to_string(v.x) & ", " & to_string(v.y) & ", " & to_string(v.z) & ")";
    end procedure;


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
        if rising_edge(clock) then

            -- vector from ray origin to sphere center
            oc := sub(ray_in.origin, sphere_in.center);

            -- quadratic equation coeffs
            a := dot(ray_in.direction, ray_in.direction);
            b := 2.0 * dot(oc, ray_in.direction);
            c := dot(oc, oc) - sphere_in.radius * sphere_in.radius;

            discriminant := b * b - 4.0 * a * c;

            if discriminant < 0.0 then
                data_out <= (
                    hit => '0',
                    position => VEC_ZERO,
                    normal => VEC_ZERO
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
                        position => VEC_ZERO,
                        normal => VEC_ZERO
                    );
                end if;
            end if;
        end if;
    end process;

end behavioral;
