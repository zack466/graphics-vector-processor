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


end package body;
