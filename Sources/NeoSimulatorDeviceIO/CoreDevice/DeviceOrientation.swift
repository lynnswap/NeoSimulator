/// The guest's orientation, in the names `devicectl` also uses: the current one, and the last upright one.
package struct GuestOrientationReading: Equatable {
    package var physical: String
    package var nonFlat: String

    package init(physical: String, nonFlat: String) {
        self.physical = physical
        self.nonFlat = nonFlat
    }
}
