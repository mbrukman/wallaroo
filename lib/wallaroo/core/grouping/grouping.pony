


trait Grouper
  fun ref apply[D: Any val](d: D): Key

class OneToOneGrouper is Grouper
  fun ref apply[D: Any val](d: D): Key =>
    "one-to-one-grouping-key"

primitive Shuffle
  fun apply(): Shuffler =>
    Shuffler()

class Shuffler is Grouper
  let _rand: Random

  fun ref apply[D: Any val](d: D): Key =>
    _rand.next().string()

trait val GroupByKey
  fun apply(): KeyGrouper

class val TypedGroupByKey[In: Any val] is GroupByKey
  let partition_function: PartitionFunction[In]

  new create(pf: PartitionFunction[In]) =>
    partition_function = pf

  fun apply(): KeyGrouper =>
    TypedKeyGrouper[In](partition_function)

trait KeyGrouper is Grouper
  fun apply[D: Any val](d: D): Key

class TypedKeyGrouper[In] is KeyGrouper
  let partition_function: PartitionFunction[In]

  new create(pf: PartitionFunction[In]) =>
    partition_function = pf

  fun ref apply[D: Any val](d: D): Key =>
    match d
    | let i: In =>
      partition_function(i)
    else
      Fail()
      ""
    end
