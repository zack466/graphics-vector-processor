-- import libraries
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;

package util is

    pure function add(u : Vec3; v : Vec3) return Vec3;
    pure function sub(u : Vec3; v : Vec3) return Vec3;
    pure function dot(u : Vec3; v : Vec3) return real;
    pure function mul(s : real; v : Vec3) return Vec3;
    pure function norm(v : Vec3) return real;
    pure function normalize(v : Vec3) return Vec3;
    pure function cross(u : Vec3; v : Vec3) return Vec3;
    pure function vec3_to_string(v : Vec3) return string;
    pure function vector_to_string(v : Vector) return string;

    type rng is protected
        impure function rand_sl return std_logic;
        impure function rand_slv(len : integer) return std_logic_vector;
        impure function rand_real(low : real; high : real) return real;
    end protected rng;

    function relatively_equal(a, b, epsilon : real) return boolean;
end package util;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.types.all;

package body util is

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

    pure function cross(u : Vec3; v : Vec3) return Vec3 is
    begin
        return (
            x => u.y * v.z - u.z * v.y,
            y => u.z * v.x - u.x * v.z,
            z => u.x * v.y - u.y * v.x
        );
    end function;

    pure function vec3_to_string(v : Vec3) return string is
    begin
        return "(" & to_string(v.x) & ", " & to_string(v.y) & ", " & to_string(v.z) & ")";
    end function;

    pure function vector_to_string(v : Vector) return string is
    begin
        return "(" & to_string(v.x) & ", " & to_string(v.y) & ", " & to_string(v.z) & ", " & to_string(v.a) & ")";
    end function;

    type rng is protected body
        variable seed1, seed2 : integer := 1000;

        impure function rand_slv(len : integer) return std_logic_vector is
            variable r : real;
            variable slv : std_logic_vector(len - 1 downto 0);
        begin
            for i in slv'range loop
                uniform(seed1, seed2, r);
                slv(i) := '1' when r > 0.5 else '0';
            end loop;
            return slv;
        end function;

        impure function rand_real(low : real; high : real) return real is
            variable r : real;
        begin
            uniform(seed1, seed2, r);
            return low + r * (high - low);
        end function;

        impure function rand_sl return std_logic is
            variable r : real;
        begin
            uniform(seed1, seed2, r);
            if r < 0.5 then
                return '1';
            else
                return '0';
            end if;
        end function;
    end protected body;

    -- reference: https://stackoverflow.com/a/27846452
    function relatively_equal(a, b, epsilon : real) return boolean is
    begin
        if a = b then -- Take care of infinities
            return true;
        elsif a * b = 0.0 then -- Either a or b is zero
            return abs(a - b) < epsilon ** 2;
        else -- Relative error
            return abs(a - b) / (abs(a) + abs(b)) < epsilon;
        end if;
    end function;

end package body;
