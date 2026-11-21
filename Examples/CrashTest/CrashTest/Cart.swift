struct Cart {
    struct Line {
        let cents: Int
        let quantity: Int?
    }

    let lines: [Line]

    func total() -> Int {
        var total = 0
        for line in lines {
            total += line.cents * line.quantity!
        }
        return total
    }
}
