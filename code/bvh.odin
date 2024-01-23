package rt

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:intrinsics"
import sm "core:container/small_array"

BVH_TARGET_LEAF_COUNT  :: 4
BVH_DEBUG_PARTITIONING :: false

BVH_Builder_Input :: struct
{
    bounds  : []Rect3,
}

BVH_Builder :: struct
{
    node_count  : u32,
    nodes       : []BVH_Node, 
    indices     : []u32,
    using input : BVH_Builder_Input,
}

BVH_Node :: struct
{
    bounds        : Rect3,
    left_or_first : u32, // left if count == 0, first if count > 0
    count         : u32,
}

#assert(size_of(BVH_Node) == 32)

BVH_Visit_Info :: struct
{
    index      : u32,
    parent     : ^BVH_Node,
    sibling    : ^BVH_Node,
    depth      : int,
}

BVH_Visitor_Args :: struct
{
    using info : ^BVH_Visit_Info,
    bvh        : ^BVH,
    node       : ^BVH_Node,
    userdata   : rawptr,
}

BVH :: struct
{
    indices : []u32,
    nodes   : []BVH_Node,
}

build_bvh_from_primitives :: proc(primitives: []Primitive_Holder, allocator := context.allocator) -> BVH
{
    if len(primitives) == 0 do return BVH{}

    temp_scoped()

    primitive_count := len(primitives)

    input: BVH_Builder_Input = {
        bounds  = make([]Rect3, primitive_count, context.temp_allocator),
    }

    for i := 0; i < primitive_count; i += 1
    {
        #no_bounds_check input.bounds[i] = find_primitive_bounds(&primitives[i].primitive)
    }

    bvh := build_bvh_from_input(input, allocator)

    return bvh
}

build_bvh_from_input :: proc(input: BVH_Builder_Input, allocator := context.allocator) -> BVH
{
    primitive_count := len(input.bounds)
    if primitive_count == 0 do return BVH{}

    nodes, _ := mem.make_aligned([]BVH_Node, 2*primitive_count, 64, allocator)
    indices  := make([]u32, primitive_count, allocator)

    for _, i in indices
    {
        #no_bounds_check indices[i] = u32(i)
    }

    builder: BVH_Builder = {
        node_count = 2,
        nodes      = nodes,
        indices    = indices,
        input      = input,
    }

    build_bvh_recursively(&builder, &builder.nodes[0], 0, u32(primitive_count))

    bvh: BVH
    bvh.nodes   = builder.nodes[:builder.node_count]
    bvh.indices = builder.indices

    return bvh
}

build_bvh :: proc {
    build_bvh_from_primitives,
    build_bvh_from_input,
}

// NOT MEANT FOR PERFORMANT ITERATION, this is just convenience for doing BVH related operations.
// Also this sucks bro... get me an iterator...
visit_bvh :: proc(bvh: ^BVH, userdata: rawptr, visitor: proc(args: BVH_Visitor_Args))
{
    stack: sm.Small_Array(32, BVH_Visit_Info)
    sm.push_back(&stack, BVH_Visit_Info{depth = 0})

    for sm.len(stack) > 0
    {
        info := sm.pop_back(&stack)
        node := &bvh.nodes[info.index]

        args := BVH_Visitor_Args{
            info     = &info,
            bvh      = bvh,
            node     = node,
            userdata = userdata,
        }
        visitor(args)

        if node.count == 0
        {
            left  := node.left_or_first
            right := left + 1
            sm.push_back(&stack, BVH_Visit_Info{
                index   = left,
                depth   = info.depth + 1, 
                parent  = node, 
                sibling = &bvh.nodes[right],
            })
            sm.push_back(&stack, BVH_Visit_Info{
                index   = right,
                depth   = info.depth + 1, 
                parent  = node, 
                sibling = &bvh.nodes[left],
            })
        }
    }
}

find_bvh_max_depth :: proc(bvh: ^BVH) -> int
{
    result: int = 0

    visit_bvh(bvh, &result, proc(args: BVH_Visitor_Args)
    {
        result_ptr := (^int)(args.userdata)
        result     := result_ptr^

        if args.depth > result
        {
            result = args.depth
        }

        result_ptr ^= result
    })

    return result
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
    pivot := 0.5*(parent_bounds.min[split_axis] + parent_bounds.max[split_axis])
    count := len(indices)

    i := 0
    j := count - 1

    when BVH_DEBUG_PARTITIONING
    {
        temp_scoped()
        indices_before := slice.clone(indices, context.temp_allocator)
    }

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

    when BVH_DEBUG_PARTITIONING
    {
        print_pivots(builder, parent_bounds, split_axis, pivot, indices_before, indices)
    }

    return u32(i), (i != 0 && i != count)
}

@(private="file")
find_pivot :: proc(builder: ^BVH_Builder, split_axis: int, index: u32) -> f32 #no_bounds_check {
    bounds := &builder.bounds[index]
    p := 0.5*(bounds.min[split_axis] + bounds.max[split_axis])
    return p
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

//
//
//

@(private="file")
debug_print_pivots :: proc(builder: ^BVH_Builder, parent_bounds: Rect3, split_axis: int, pivot: f32, 
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

test_bvh_reachability :: proc(bvh: ^BVH, entry_count: int) -> bool
{
    temp_scoped()

    indices_touched := make([]bool, entry_count, allocator=context.temp_allocator)

    visit_bvh(bvh, &indices_touched, proc(args: BVH_Visitor_Args) 
    {
        bvh      := args.bvh
        node     := args.node
        userdata := args.userdata

        if node.count > 0
        {
            indices_touched := (^[]bool)(userdata)^
            
            first := node.left_or_first
            count := node.count

            for i := first; i < first + count; i += 1
            {
                indices_touched[i] = true
            }
        }
    })

    visited_all := true

    for was_touched in indices_touched
    {
        if !was_touched
        {
            visited_all = false
            break
        }
    }

    return visited_all
}

