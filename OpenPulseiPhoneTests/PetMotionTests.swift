import Testing
@testable import OpenPulseiPhone

struct PetMotionTests {
    @Test
    func patrolPausesThenWalksAcrossTheBoundedStage() {
        let atLeft = PetMotion.movement(for: .patrol, phase: 0)
        let movingRight = PetMotion.movement(for: .patrol, phase: .pi * 0.6)
        let movingLeft = PetMotion.movement(for: .patrol, phase: .pi * 1.6)

        #expect(atLeft.offset.width == -48)
        #expect(atLeft.stride == 0)
        #expect(movingRight.offset.width > -48 && movingRight.offset.width < 48)
        #expect(movingRight.facingScaleX == 1)
        #expect(movingLeft.facingScaleX == -1)
    }
}
