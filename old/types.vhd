-- import libraries
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package types is

type Vector is record
    x : real;
    y : real;
    z : real;
    a : real;
end record;

constant VEC_ZERO : Vector := (
    x => 0.0,
    y => 0.0,
    z => 0.0,
    a => 0.0
);

type Vec3 is record
    x : real;
    y : real;
    z : real;
end record;

constant VEC3_ZERO : Vec3 := (
    x => 0.0,
    y => 0.0,
    z => 0.0
);

type Color is record
    r : real;
    g : real;
    b : real;
end record;

type Ray is record
    origin      : Vec3;
    direction   : Vec3;
end record;

type Material is record
    color       : Color;        -- Base color of the material
    emission    : real;         -- Emission strength (0 for non-emitting)
    reflective  : std_logic;    -- if the matieral is matte (0) or metallic (1)
end record;

type Sphere is record
    center      : Vec3;
    radius      : real;
end record;

type IntersectionData is record
    hit         : std_logic;    -- Whether the ray hit anything
    position    : Vec3;         -- Intersection position
    normal      : Vec3;         -- Surface normal at intersection point
end record;

type Camera is record
    position    : Vec3;     -- Camera position in world space
    forward     : Vec3;     -- Forward direction (normalized)
    up          : Vec3;     -- Up direction (normalized)
    right       : Vec3;     -- Right direction (normalized)
    fov         : Real;     -- Field of view in radians
    aspect      : Real;     -- Aspect ratio (width/height)
end record;

end package types;
