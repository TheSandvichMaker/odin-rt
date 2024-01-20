package rt

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:intrinsics"

BVH_TARGET_LEAF_COUNT :: 8

BVH_Builder_Input :: struct
{
    indices : []u32,
    bounds  : []Rect3,
}

BVH_Builder :: struct
{
    bvh: ^BVH,
    node_count  : u32,
    nodes       : []BVH_Node, 
    using input : BVH_Builder_Input,
}

BVH_Node :: struct
{
    bounds        : Rect3,
    left_or_first : u32, // left if count == 0, first if count > 0
    count         : u32,
}

#assert(size_of(BVH_Node) == 32)

BVH :: struct
{
    nodes: []BVH_Node,
}

build_bvh_from_primitives :: proc(primitives: []Primitive_Holder, allocator := context.allocator) -> BVH
{
    bvh: BVH

    {
        temp_scoped()

        primitive_count := len(primitives)

        input: BVH_Builder_Input = {
            bounds  = make([]Rect3, primitive_count, context.temp_allocator),
            indices = make([]u32,   primitive_count, context.temp_allocator),
        }

        for i := 0; i < primitive_count; i += 1
        {
            #no_bounds_check input.indices[i] = u32(i)
            #no_bounds_check input.bounds [i] = find_primitive_bounds(&primitives[i].primitive)
        }

        bvh = build_bvh_from_input(input, allocator)
    }

    return bvh
}

build_bvh_from_input :: proc(input: BVH_Builder_Input, allocator := context.allocator) -> BVH
{
    primitive_count := len(input.indices)
    assert(len(input.bounds) == primitive_count)

    bvh: BVH

    nodes, _ := mem.make_aligned([]BVH_Node, 2*primitive_count, 64, allocator)

    builder: BVH_Builder = {
        bvh        = &bvh,
        node_count = 2,
        nodes      = nodes,
        input      = input,
    }

    build_bvh_recursively(&builder, &builder.nodes[0], 0, u32(primitive_count))
    bvh.nodes = builder.nodes[:builder.node_count]

    return bvh
}

build_bvh :: proc {
    build_bvh_from_primitives,
    build_bvh_from_input,
}

@(private="file")
build_bvh_recursively :: proc(builder: ^BVH_Builder, parent: ^BVH_Node, first: u32, count: u32)
{
    assert(count > 0)

    indices := builder.indices[first:][:count]

    bv := compute_bounding_volume(builder, indices)
    parent.bounds = bv

    if len(indices) <= BVH_TARGET_LEAF_COUNT
    {
        parent.left_or_first = first
        parent.count         = count
    }
    else
    {
        split_index := count / 2
        split_axis  := rect3_find_largest_axis(bv)

        index, ok := partition_objects(builder, bv, split_axis, indices)
        if !ok do index, ok = partition_objects(builder, bv, split_axis + 1 % 3, indices) 
        if !ok do index, ok = partition_objects(builder, bv, split_axis + 2 % 3, indices) 

        if ok do split_index = index

        l_index := builder.node_count; builder.node_count += 1
        r_index := builder.node_count; builder.node_count += 1

        parent.left_or_first = l_index

        l_node := &builder.nodes[l_index]
        build_bvh_recursively(builder, l_node, first, split_index)

        r_node := &builder.nodes[r_index]
        build_bvh_recursively(builder, r_node, first + split_index, count - split_index)
    }
}

@(private="file")
compute_bounding_volume :: proc(builder: ^BVH_Builder, indices: []u32) -> Rect3
{
    result := rect3_inverted_infinity()

    for index in indices
    {
        #no_bounds_check bounds := builder.bounds[index]
        result = rect3_union(result, bounds)
    }

    return result
}

@(private="file")
partition_objects :: proc(builder: ^BVH_Builder, parent_bounds: Rect3, split_axis: int, indices: []u32) -> (u32, bool) #no_bounds_check {
    pivot      := 0.5*(parent_bounds.min[split_axis] + parent_bounds.max[split_axis])
    
    count := len(indices)

    i := 0
    j := count - 1

    find_pivot :: proc(builder: ^BVH_Builder, split_axis: int, index: u32) -> f32 #no_bounds_check {
        bounds := &builder.bounds[index]
        p := 0.5*(bounds.min[split_axis] + bounds.max[split_axis])
        return p
    }

    print_pivots :: proc(builder: ^BVH_Builder, parent_bounds: Rect3, split_axis: int, pivot: f32, 
                         indices_before: []u32, indices: []u32)
    {
        @(thread_local)
        partition_count := 0

        axis_names := [?]string { "X", "Y", "Z" }
        fmt.printf("pivot swaps #%v (axis: %v bounds: %v):\n", partition_count, axis_names[split_axis], parent_bounds)

        printed_count := 0

        for _, i in indices
        {
            index_before := indices_before[i]
            index_after  := indices[i]

            PRINT_ALL :: false
            if PRINT_ALL || index_before != index_after
            {
                p_before := find_pivot(builder, split_axis, index_before)
                p_after  := find_pivot(builder, split_axis, index_after)

                fmt.printf("\t#%v\t", i)

                if index_before == index_after
                {
                    fmt.printf("(%v)\t\t", index_after)
                }
                else
                {
                    fmt.printf("(%v -> %v)\t", index_before, index_after)
                }

                fmt.printf("%v %v %v (%v)\n", p_after, p_after < pivot ? "<" : ">", pivot, p_before)

                printed_count += 1
            }
        }

        if printed_count == 0
        {
            fmt.printf("\tno swaps occurred. that is definitely a bug.\n")
        }

        fmt.printf("bounds:\n")
        for index, i in indices
        {
            bounds := builder.bounds[index]
            p := find_pivot(builder, split_axis, index)
            fmt.printf("\t#%v(%v)\t%v (%v)\n", i, index, bounds, p)
        }

        partition_count += 1
    }

    temp_scoped()
    indices_before := slice.clone(indices, context.temp_allocator)

    for
    {
        for ; i < count; i += 1
        {
            if find_pivot(builder, split_axis, indices[i]) > pivot do break
        }

        for ; j >= 0; j -= 1
        {
            if find_pivot(builder, split_axis, indices[j]) < pivot do break
        }

        if i >= j do break

        indices[i], indices[j] = indices[j], indices[i]
    }

    print_pivots(builder, parent_bounds, split_axis, pivot, indices_before, indices)

    return u32(i), (i != 0 && i != count)
}

@(private="file")
find_primitive_bounds :: proc(primitive: ^Primitive) -> (result: Rect3)
{
    switch primitive.kind
    {
        case .SPHERE:
            sphere := cast(^Sphere)primitive
            result = rect3_center_radius(sphere.p, sphere.r)
        case .BOX:
            box := cast(^Box)primitive
            result = rect3_center_radius(box.p, box.r)
        case .PLANE:
            panic("Don't put an infinite plane in a BVH!")
    }
    return result
}

